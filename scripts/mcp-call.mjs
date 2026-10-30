// Starts MobileBuildMCP over stdio in a project folder, as an MCP client does, calls one tool, and prints the text of
// its result. Captures come from MCP results, not the CLI's, which presents the same tools differently.
// node scripts/mcp-call.mjs <project folder> <tool> ['<arguments as JSON>']
import { spawn } from 'node:child_process'

const [project, tool, args = '{}'] = process.argv.slice(2)
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
  console.error(`mcp-call: ${tool} took longer than ten minutes`)
  server.kill()
  process.exit(2)
}, 600_000)
await request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'xcrew-testbed', version: '0' } })
server.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n')
const called = await request('tools/call', { name: tool, arguments: JSON.parse(args) })
clearTimeout(timer)
server.kill()
if (!called.result) {
  console.error(`mcp-call: ${JSON.stringify(called.error)}`)
  process.exit(1)
}
process.stdout.write(called.result.content.map(part => part.text ?? '').join(''), () => process.exit(0))
