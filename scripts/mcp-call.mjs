// Starts MobileBuildMCP over stdio in a project folder, as an MCP client does, calls one tool, or several one after
// another in the one session, as a stateful tool needs, and prints the text of the last result. Captures come from MCP
// results, not the CLI's, which presents the same tools differently.
// node scripts/mcp-call.mjs <project folder> <tool> ['<arguments as JSON>'] [<tool> '<arguments as JSON>' …]
import { spawn } from 'node:child_process'

const [project, ...rest] = process.argv.slice(2)
const calls = []
for (let i = 0; i < rest.length; i += 2) calls.push([rest[i], rest[i + 1] ?? '{}'])
const server = spawn('mobilebuildmcp', ['mcp'], { cwd: project, stdio: ['pipe', 'pipe', 'ignore'] })
const pending = new Map()
let buffer = ''
server.stdout.on('data', chunk => {
  buffer += chunk
  let newline
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline)
    buffer = buffer.slice(newline + 1)
    if (line.trim()) {
      const message = JSON.parse(line)
      pending.get(message.id)?.(message)
    }
  }
})
let next = 1
const request = (method, params) => new Promise(resolve => {
  const id = next++
  pending.set(id, resolve)
  server.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
})
const timer = setTimeout(() => {
  console.error(`mcp-call: ${calls.map(([tool]) => tool).join(', ')} took longer than ten minutes`)
  server.kill()
  process.exit(2)
}, 600_000)
await request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'xcrew-testbed', version: '0' } })
server.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n')
let called
for (const [index, [tool, args]] of calls.entries()) {
  called = await request('tools/call', { name: tool, arguments: JSON.parse(args) })
  const text = called.result?.content.map(part => part.text ?? '').join('') ?? ''
  // Each step's result on stderr, for the run's log: what a later step stands on.
  if (calls.length > 1) console.error(`mcp-call: ${tool}${called.result?.isError ? ' (error)' : ''}:\n${text.slice(0, 3000)}`)
  // A step before the last that failed leaves nothing to capture: the scenario didn't happen.
  if (index < calls.length - 1 && (!called.result || called.result.isError)) {
    console.error(`mcp-call: ${tool} failed: ${called.result ? text : JSON.stringify(called.error)}`)
    server.kill()
    process.exit(1)
  }
}
clearTimeout(timer)
server.kill()
if (!called.result) {
  console.error(`mcp-call: ${JSON.stringify(called.error)}`)
  process.exit(1)
}
process.stdout.write(called.result.content.map(part => part.text ?? '').join(''), () => process.exit(0))
