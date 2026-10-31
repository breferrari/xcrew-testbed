# What a capture's PATH holds in place of the capturing Mac's own, whose tools are no capture's business: an Xcode app's
# own entries, which Xcode sets, then macOS's defaults. Sourced by generate.sh, which writes every PATH through
# `neutral_path`, and by leaks.sh, which fails on a file `neutral_path` would change.
neutral_path_defaults=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# Every PATH a tool writes: `PATH=…` as an environment lists it, `export PATH\=…` as xcodebuild echoes it, either one
# inside a JSON string (`PATH\\=`, `\/`), and a value in quotes. Never another variable whose name ends in PATH. A
# value runs to a space, a quote or a backslash that escapes neither a space nor a slash, so `Application\ Support` is
# one entry and a JSON `\n` ends it.
neutral_path() {
  perl -pe '
    BEGIN { $defaults = shift @ARGV }
    s{(?<![A-Za-z0-9_])(PATH(?:\\\\|\\)?=)(["\x27]?)((?:\\ |\\/|[^\s"\x27\\])+)}{
      my ($name, $quote, $value) = ($1, $2, $3);
      my $escaped = $value =~ m{\\/};
      (my $plain = $value) =~ s{\\/}{/}g;
      my $kept = join(":", (grep { m{^[^:]*/Xcode[^/]*\.app/Contents/} } split(/:/, $plain)), $defaults);
      $kept =~ s{/}{\\/}g if $escaped;
      $name . $quote . $kept
    }ge
  ' "$neutral_path_defaults"
}
