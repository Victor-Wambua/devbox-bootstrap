#!/usr/bin/env bash
# Builds the docs site and the generated Brewfiles from the profile manifests.
#
#   scripts/build-docs.sh
#
# Everything on the profile pages (steps, options, manifest source, Brewfile) is read
# from profiles/*.conf by devbox's own parser, and the terminal sessions on the landing
# page are real devbox output captured by scripts/capture-demo.sh. Nothing here is
# written by hand per profile, so the site cannot drift from the manifests.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
site=$root/docs
src=$root/scripts/site
repo_url="https://github.com/Victor-Wambua/devbox-bootstrap"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/devbox-docs.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Use devbox's own parser, with an empty HOME so nobody's personal profiles leak in.
export HOME=$tmp/home
mkdir -p "$HOME"
unset DEVBOX_PROFILE_PATH
export DEVBOX_ROOT=$root
for lib in core semver manifest; do
  # shellcheck source=/dev/null
  source "$root/lib/$lib.sh"
done

mkdir -p "$site/assets" "$site/profiles" "$root/Brewfiles"
cp "$src/style.css" "$site/assets/style.css"
cp "$src/logo.svg" "$site/assets/logo.svg"

# ---- helpers ------------------------------------------------------------------------

esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# ansi_html FILE -> HTML-escaped text with devbox's SGR codes turned into spans
ansi_html() {
  local esc_char=$'\033'
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1" |
    sed -E -e "s/${esc_char}\[0m/<\/span>/g" -e "s/${esc_char}\[([0-9]+)m/<span class=\"a\1\">/g"
}

logo_inline() { sed -e 's/ role="img" aria-label="devbox"/ aria-hidden="true" focusable="false"/' "$src/logo.svg"; }

page_start() { # TITLE DESCRIPTION RELROOT CURRENT
  local title=$1 desc=$2 rel=$3 cur=${4:-}
  local c_prof="" c_guide=""
  [[ $cur == profiles ]] && c_prof=' aria-current="page"'
  [[ $cur == guide ]] && c_guide=' aria-current="page"'
  cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(esc "$title")</title>
<meta name="description" content="$(esc "$desc")">
<meta name="color-scheme" content="light dark">
<link rel="icon" href="${rel}assets/logo.svg" type="image/svg+xml">
<link rel="stylesheet" href="${rel}assets/style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site-header">
  <div class="wrap">
    <a class="brand" href="${rel}index.html">$(logo_inline)<span>devbox</span></a>
    <nav class="nav" aria-label="Main">
      <a href="${rel}profiles/index.html"$c_prof>Profiles</a>
      <a href="${rel}guide.html"$c_guide>Write your own</a>
      <a href="$repo_url">GitHub</a>
    </nav>
  </div>
</header>
<main id="main">
HTML
}

page_end() {
  cat <<HTML
</main>
<footer>
  <div class="wrap">
    <span>Built by Victor Wambua · <a href="https://victor-wambua.github.io/victor-portfolio/">portfolio</a> · <a href="https://github.com/Victor-Wambua/case-studies">case studies</a></span>
    <span>MIT licensed · <a href="$repo_url">source</a> · portfolio build, exercised against a mocked machine only</span>
  </div>
</footer>
</body>
</html>
HTML
}

kind_blurb() {
  case $1 in
    formula) echo "Installs a Homebrew formula. Doctor also checks the binary is on PATH and meets min." ;;
    cask) echo "Installs a Homebrew cask. Give bin to have doctor check its command line tool." ;;
    service) echo "A Homebrew service. With start=yes apply starts it; otherwise it is only checked by doctor." ;;
    tool) echo "An expectation devbox never installs (for example a tool macOS ships). Doctor checks it." ;;
    cmd) echo "Runs a command. check decides if it is already done and must be read-only. sudo=yes lets it prompt." ;;
    block) echo "Owns a marked region of a file under your home directory, one line= option per line." ;;
    defaults) echo "Sets one macOS preference. The previous value is saved to a restore script first." ;;
    vscode) echo "Installs a VS Code extension by id." ;;
    uvpython) echo "Installs a Python version with uv." ;;
    installer) echo "Downloads from an https URL, verifies sha256, then runs it. Needs --yes." ;;
  esac
}

# profile_meta NAME -> sets P_SUMMARY, P_INCLUDES (space separated), P_OWN (own step count), P_STEPS (resolved)
profile_meta() {
  local path
  path=$(manifest_find "$1")
  manifest_parse_file "$path" "$1" || { echo "build-docs: $MANIFEST_ERR" >&2; exit 1; }
  P_SUMMARY=$PARSED_SUMMARY
  P_INCLUDES=${PARSED_INCLUDES[*]-}
  P_OWN=${#PARSED_STEPS[@]}
  manifest_resolve "$1" || { echo "build-docs: $MANIFEST_ERR" >&2; exit 1; }
  P_STEPS=${#STEPS[@]}
}

names=()
while IFS= read -r n; do names+=("$n"); done < <(manifest_all_names)

# ---- 1. Brewfiles ---------------------------------------------------------------------

for n in "${names[@]}"; do
  env -i HOME="$HOME" PATH="$PATH" bash "$root/bin/devbox" list --brewfile --profile "$n" >"$root/Brewfiles/$n.Brewfile"
done

# ---- 2. captures ------------------------------------------------------------------------

"$root/scripts/capture-demo.sh" "$tmp/ansi" >/dev/null

# ---- 3. profile cards (shared by the landing page and the index) --------------------------

profile_cards() { # RELPREFIX
  local n
  for n in "${names[@]}"; do
    profile_meta "$n"
    local inc=""
    [[ -n $P_INCLUDES ]] && inc="includes $P_INCLUDES · "
    cat <<HTML
      <a class="card" href="$1$n.html">
        <h3><span>$(esc "$n")</span></h3>
        <p>$(esc "$P_SUMMARY")</p>
        <p class="meta">$(esc "$inc")$P_STEPS steps</p>
      </a>
HTML
  done
}

# ---- 4. landing page ------------------------------------------------------------------------

{
  page_start "devbox: your laptop setup, written down" \
    "An idempotent, auditable macOS developer-machine bootstrap with profiles for PHP/Laravel and Valet, Python, Node and Salesforce, and a doctor command." "" ""
  cat <<HTML
<div class="hero">
  <div class="wrap">
    <p class="eyebrow">macOS · bash 3.2+ · MIT</p>
    <h1>Your laptop setup, written down and checkable.</h1>
    <p class="lede">devbox is an idempotent bootstrap for developer Macs. <strong>Plan</strong> shows what would change. <strong>Apply</strong> changes only that, and running it again changes nothing. <strong>Doctor</strong> tells you what is missing or has drifted.</p>
    <div class="cta">
      <a class="btn primary" href="profiles/index.html">Browse the profiles</a>
      <a class="btn" href="$repo_url">View on GitHub</a>
    </div>
    <p style="margin:24px 0 0"><span class="label">Try it without touching your machine</span></p>
    <div class="install" tabindex="0" role="region" aria-label="Try command">git clone $repo_url &amp;&amp; cd devbox-bootstrap &amp;&amp; scripts/try.sh -- plan --profile php-laravel</div>

    <div class="terminal" id="terminal">
      <div class="t-bar">
        <div class="t-dots" aria-hidden="true"><i></i><i></i><i></i></div>
        <div class="t-tabs" role="tablist" aria-label="Captured sessions">
          <button class="t-tab" role="tab" id="tab-plan" aria-controls="panel-plan" aria-selected="true" type="button">plan</button>
          <button class="t-tab" role="tab" id="tab-apply" aria-controls="panel-apply" aria-selected="false" tabindex="-1" type="button">apply, twice</button>
          <button class="t-tab" role="tab" id="tab-doctor" aria-controls="panel-doctor" aria-selected="false" tabindex="-1" type="button">doctor</button>
        </div>
      </div>
      <div class="t-body" tabindex="0" role="region" aria-label="Terminal output (scrollable)">
        <div class="t-panel" id="panel-plan" role="tabpanel" aria-labelledby="tab-plan"><pre>$(ansi_html "$tmp/ansi/plan.ansi")</pre></div>
        <div class="t-panel" id="panel-apply" role="tabpanel" aria-labelledby="tab-apply" hidden><pre>$(ansi_html "$tmp/ansi/apply.ansi")</pre></div>
        <div class="t-panel" id="panel-doctor" role="tabpanel" aria-labelledby="tab-doctor" hidden><pre>$(ansi_html "$tmp/ansi/doctor.ansi")</pre></div>
      </div>
    </div>
    <p class="t-caption">This is real output of <code>bin/devbox</code>, captured by <code>scripts/capture-demo.sh</code> against the mocked machine the test suite uses: a fake Homebrew and a temp <code>HOME</code>. Versions are fixture values, not release data. The temp directory is shown as <code>/opt/homebrew</code> and <code>/usr/bin</code>, and backup timestamps as <code>YYYYMMDD-HHMMSS</code>. Nothing here was run against a real Mac.</p>
  </div>
</div>

<section>
  <div class="wrap">
    <h2>Setup that lives in someone's head</h2>
    <div class="split">
      <div class="prose">
        <p>A new laptop is a day of installing and tweaking. Two people on the same team end up with different PHP versions and different PATHs. When a laptop dies, the answer to "how was it set up?" goes with it.</p>
        <p>The usual fixes are a wiki page that rots or a shell script that only works once. devbox keeps the setup in small manifest files in git, and every step knows how to check itself, so it is safe to run again whenever you like.</p>
      </div>
      <div>
        <p class="label">What a profile looks like</p>
        <pre class="code" tabindex="0"><code>$(esc "$(sed -n '1,40p' "$root/profiles/node.conf")")</code></pre>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <h2>Four rules the tool keeps</h2>
    <p class="section-lede">A tool that edits your dotfiles has to earn trust. These are the properties the tests pin down.</p>
    <div class="grid four">
      <div class="card"><span class="num">01</span><h3>Plan before apply</h3><p><code>devbox</code> with no arguments is <code>plan</code>. It prints the exact command for every change, and with <code>--dry-run</code> the tests assert that nothing on the machine moved.</p></div>
      <div class="card"><span class="num">02</span><h3>Idempotent steps</h3><p>Every step has a check. Apply runs only unsatisfied steps, then re-checks. The second run is a no-op, for every bundled profile.</p></div>
      <div class="card"><span class="num">03</span><h3>Managed blocks</h3><p>Shell config edits live between begin and end markers and are replaced in place, never appended twice. Your own lines are left alone.</p></div>
      <div class="card"><span class="num">04</span><h3>Backups and a log</h3><p>Files are copied to <code>~/.devbox/backups/</code> before they change, macOS defaults get a restore script, and every run appends to a log.</p></div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <div class="split">
      <div class="prose">
        <h2>Managed blocks, not appended lines</h2>
        <p>Re-running a script that does <code>echo ... &gt;&gt; ~/.zshrc</code> adds the line again each time. devbox writes a region with markers and replaces that region on the next run. If you edit inside it, doctor reports drift and apply puts it back. If the markers are damaged, devbox refuses to guess and tells you to fix it by hand.</p>
        <p>This is the dotfile from the sandbox after one apply, with three lines of the user's own above the block.</p>
      </div>
      <div>
        <pre class="code" tabindex="0" aria-label="Contents of .zprofile after apply"><code>$(ansi_html "$tmp/ansi/block.ansi")</code></pre>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <h2>Profiles</h2>
    <p class="section-lede">Each profile is a manifest in <code>profiles/</code>. They can include each other. These cards, and every page behind them, are generated from the manifests.</p>
    <div class="grid three">
$(profile_cards "profiles/")
    </div>
  </div>
</section>

<section>
  <div class="wrap">
    <h2>What it does not do</h2>
    <div class="prose">
      <ul>
        <li>It is macOS only. It refuses to run elsewhere, and refuses to run as root.</li>
        <li>It has been exercised against a mocked <code>brew</code>, <code>defaults</code> and friends, not end to end on a clean Mac. Real installs, and Laravel Valet's real behaviour, are unverified.</li>
        <li>It does not install Homebrew for you. It tells you where to get it, rather than piping an installer into a shell.</li>
        <li>It manages what a profile declares. It will not discover and remove things you installed by hand.</li>
      </ul>
    </div>
  </div>
</section>

<script>
(function () {
  var root = document.documentElement;
  root.classList.add('js');
  var tabs = Array.prototype.slice.call(document.querySelectorAll('.t-tab'));
  function show(tab) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute('aria-selected', on ? 'true' : 'false');
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
  }
  tabs.forEach(function (t, i) {
    t.addEventListener('click', function () { show(t); });
    t.addEventListener('keydown', function (e) {
      var j = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : -1;
      if (j < 0) return;
      e.preventDefault();
      j = (j + tabs.length) % tabs.length;
      show(tabs[j]);
      tabs[j].focus();
    });
  });
  show(tabs[0]);
})();
</script>
HTML
  page_end
} >"$site/index.html"

# ---- 5. profile index and pages -----------------------------------------------------------------

{
  page_start "devbox profiles" "All bundled devbox profiles, generated from the manifests." "../" profiles
  cat <<HTML
<div class="wrap">
  <div class="page-head">
    <div class="crumbs"><a href="../index.html">devbox</a> / profiles</div>
    <h1>Profiles</h1>
    <p class="lede">${#names[@]} bundled profiles. Pick one or several: <code>devbox plan --profile php-laravel,python</code>. Your own profiles in <code>~/.devbox/profiles/</code> appear in <code>devbox profiles</code> too; <a href="../guide.html">here is how to write one</a>.</p>
  </div>
  <div class="grid three" style="padding-bottom:64px">
$(profile_cards "")
  </div>
</div>
HTML
  page_end
} >"$site/profiles/index.html"

option_cell() { # REC -> human readable options
  local rec=$1 line k v out=""
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    k=${line%%=*}
    v=${line#*=}
    case $k in
      why) ;;
      run | check)
        out+="<div><span class=\"muted\">$k</span> <code>$(esc "$v")</code></div>" ;;
      line)
        out+="<div><span class=\"muted\">line</span> <code>$(esc "$v")</code></div>" ;;
      *) out+="<span class=\"chip\">$(esc "$k=$v")</span>" ;;
    esac
  done < <(rec_options "$rec")
  printf '%s' "$out"
}

for n in "${names[@]}"; do
  profile_meta "$n"
  path=$(manifest_find "$n")
  incl_html=""
  for i in $P_INCLUDES; do incl_html+="<a class=\"chip\" href=\"$i.html\">$(esc "$i")</a>"; done
  {
    page_start "devbox profile: $n" "$P_SUMMARY" "../" profiles
    cat <<HTML
<div class="wrap">
  <div class="page-head">
    <div class="crumbs"><a href="../index.html">devbox</a> / <a href="index.html">profiles</a> / $(esc "$n")</div>
    <h1>$(esc "$n")</h1>
    <p class="lede">$(esc "$P_SUMMARY")</p>
    <div class="stats">
      <div class="stat"><b>$P_STEPS</b><span>steps in total</span></div>
      <div class="stat"><b>$P_OWN</b><span>defined here</span></div>
      <div class="stat"><b>$(( ${#RESOLVED_PROFILES[@]} - 1 ))</b><span>profiles included</span></div>
    </div>
HTML
    if [[ -n $incl_html ]]; then
      printf '    <p style="margin-top:16px"><span class="label">Includes</span><br>%s</p>\n' "$incl_html"
    fi
    cat <<HTML
    <p style="margin-top:24px"><span class="label">Use it</span></p>
    <div class="install" tabindex="0" role="region" aria-label="Commands">devbox plan --profile $(esc "$n") &amp;&amp; devbox apply --profile $(esc "$n") &amp;&amp; devbox doctor --profile $(esc "$n")</div>
  </div>

  <section style="padding-top:32px">
    <h2>Steps</h2>
    <p class="section-lede">In the order devbox runs them. Included profiles come first.</p>
    <div class="table-wrap" tabindex="0" role="region" aria-label="Steps of $(esc "$n")">
      <table>
        <thead><tr><th>Kind</th><th>Id</th><th>From</th><th>Details</th><th>Why</th></tr></thead>
        <tbody>
HTML
    for rec in "${STEPS[@]}"; do
      printf '          <tr><td><span class="kind">%s</span></td><td class="mono">%s</td><td class="mono">%s</td><td>%s</td><td class="muted">%s</td></tr>\n' \
        "$(rec_kind "$rec")" "$(esc "$(rec_id "$rec")")" "$(esc "$(rec_origin "$rec")")" "$(option_cell "$rec")" "$(esc "$(rec_opt "$rec" why)")"
    done
    cat <<HTML
        </tbody>
      </table>
    </div>
  </section>

  <section>
    <div class="split">
      <div>
        <h2>Manifest</h2>
        <p class="label">profiles/$(esc "$n").conf</p>
        <pre class="code" tabindex="0"><code>$(esc "$(cat "$path")")</code></pre>
      </div>
      <div>
        <h2>Brewfile</h2>
        <p class="label">Brewfiles/$(esc "$n").Brewfile (generated)</p>
        <pre class="code" tabindex="0"><code>$(esc "$(cat "$root/Brewfiles/$n.Brewfile")")</code></pre>
        <p class="section-lede" style="margin-top:12px">For people who want a plain Brewfile. Only formulae, casks and VS Code extensions have a Brewfile form; the rest need <code>devbox apply</code>.</p>
      </div>
    </div>
  </section>
</div>
HTML
    page_end
  } >"$site/profiles/$n.html"
done

# ---- 6. the guide ---------------------------------------------------------------------------------------

{
  page_start "Write your own devbox profile" "How to write, test and share a devbox profile: format, step kinds, managed blocks and safety rules." "" guide
  cat <<HTML
<div class="wrap">
  <div class="page-head">
    <div class="crumbs"><a href="index.html">devbox</a> / write your own</div>
    <h1>Write your own profile</h1>
    <p class="lede">A profile is a plain text file. It says what a machine should look like; devbox works out what to do. You can start from an existing one, or capture your current laptop with <code>devbox export</code>.</p>
  </div>
  <div class="prose" style="padding-bottom:64px">
    <h2>Where profiles live</h2>
    <p>devbox looks for <code>NAME.conf</code> in these places, and the first match wins:</p>
    <ol>
      <li>Each directory in <code>\$DEVBOX_PROFILE_PATH</code> (colon separated).</li>
      <li><code>~/.devbox/profiles/</code></li>
      <li>The <code>profiles/</code> directory that ships with devbox.</li>
    </ol>
    <p>So a team can keep its profiles in a git repo, point <code>DEVBOX_PROFILE_PATH</code> at a checkout, and even override a bundled profile by reusing its name.</p>

    <h2>A first profile</h2>
<pre class="code" tabindex="0"><code>$(esc '# ~/.devbox/profiles/team-web.conf
summary: "What our web team installs"
include: base node

formula postgresql@16 min=16.0 why="Matches production"
cask    docker bin=docker

block   team-env file="~/.zshrc" line="export COMPOSE_PROJECT_NAME=web"
cmd     clone-monorepo run="git clone git@github.com:example/web.git ~/code/web" check="test -d ~/code/web/.git"')</code></pre>
    <p>Then:</p>
<pre class="code" tabindex="0"><code>devbox plan --profile team-web      # what would change, and the exact commands
devbox apply --profile team-web     # make it so (asks first)
devbox doctor --profile team-web    # what has drifted since</code></pre>

    <h2>The format</h2>
    <p>One directive per line. A line is either a header (<code>summary:</code> or <code>include:</code>) or a step: a kind, an id, then <code>key=value</code> options. Use double quotes around values that contain spaces. Inside quotes, <code>\\"</code> and <code>\\\\</code> are the only escapes. <code>#</code> starts a comment at the start of a word.</p>
    <div class="callout"><p>The parser never evaluates anything. <code>\$HOME</code>, backticks and <code>\$( )</code> inside a value are kept as literal text; they only run if you put them in a <code>cmd</code> or <code>check</code> string, which devbox runs with <code>bash -c</code> after showing it to you in the plan.</p></div>

    <h2>Step kinds</h2>
  </div>
  <div class="table-wrap" tabindex="0" role="region" aria-label="Step kinds" style="margin-bottom:64px">
    <table>
      <thead><tr><th>Kind</th><th>Required</th><th>Optional</th><th>What it does</th></tr></thead>
      <tbody>
HTML
  for k in $MANIFEST_KINDS; do
    req=$(manifest_kind_required "$k")
    allowed=$(manifest_kind_allowed "$k")
    opt=""
    for a in $allowed; do
      case " $req " in *" $a "*) ;; *) opt+="<span class=\"chip\">$a</span>" ;; esac
    done
    reqh=""
    for a in $req; do reqh+="<span class=\"chip\">$a</span>"; done
    printf '        <tr><td><span class="kind">%s</span></td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$k" "${reqh:-<span class=\"muted\">id only</span>}" "$opt" "$(esc "$(kind_blurb "$k")")"
  done
  cat <<HTML
      </tbody>
    </table>
  </div>
  <div class="prose" style="padding-bottom:64px">
    <h2>Rules that keep profiles safe</h2>
    <ul>
      <li><strong>Every step needs a way to tell it is done.</strong> Built-in kinds have one. For <code>cmd</code>, the <code>check</code> must be read-only and exit 0 only when the work is already done. Apply re-runs the check afterwards, and a step that does not pass it is reported as failed.</li>
      <li><strong>Blocks only touch your home directory.</strong> <code>file</code> must start with <code>~/</code> and may not contain <code>..</code>. Block ids are unique per profile set; two profiles that define the same step identically are merged, and conflicting definitions are an error.</li>
      <li><strong>Profiles are code.</strong> A <code>cmd</code> runs with your privileges. Read a teammate's profile as you would read a script, and read the plan before you apply it.</li>
      <li><strong>Upstream installers are a last resort.</strong> An <code>installer</code> step downloads over https, verifies a pinned sha256 and only then runs the file. It is never run without <code>--yes</code>. None of the bundled profiles uses one.</li>
      <li><strong>Prefer Homebrew steps</strong> to <code>cmd</code> where you can: they are checked, listed in the Brewfile and shown by doctor with versions.</li>
    </ul>

    <h2>Managed blocks</h2>
    <p>A <code>block</code> step owns this region of the file, and nothing else in it:</p>
<pre class="code" tabindex="0"><code>$(esc '# >>> devbox:team-env >>> managed by devbox; edits between the markers are overwritten
export COMPOSE_PROJECT_NAME=web
# <<< devbox:team-env <<<')</code></pre>
    <p>If the block is missing, apply appends it once. If its content differs from the profile, apply replaces it in place. If the markers are unbalanced or duplicated, devbox marks the step blocked and changes nothing. Before any file changes, the original is copied to <code>~/.devbox/backups/&lt;time&gt;/files/</code>.</p>

    <h2>Test a profile safely</h2>
    <ol>
      <li><code>devbox list --profile team-web</code> parses it and shows the resolved steps, with no machine access.</li>
      <li><code>scripts/try.sh -- plan --profile team-web</code> runs devbox against a throwaway mocked machine: temp <code>HOME</code>, mock <code>brew</code>, nothing real.</li>
      <li><code>devbox plan --check --profile team-web</code> exits 4 while anything is pending, which makes a cheap drift check in CI or a login script.</li>
    </ol>

    <h2>Exit codes</h2>
    <div class="table-wrap" style="margin-top:16px"><table>
      <thead><tr><th>Code</th><th>Meaning</th></tr></thead>
      <tbody>
        <tr><td class="mono">0</td><td>Success. For doctor: no failures (warnings allowed).</td></tr>
        <tr><td class="mono">1</td><td>A step failed, or doctor found failures.</td></tr>
        <tr><td class="mono">2</td><td>Bad flags, or a manifest that does not parse or has an include cycle.</td></tr>
        <tr><td class="mono">3</td><td>Refused by a safety rule: root, not macOS, no <code>--yes</code>, Homebrew missing.</td></tr>
        <tr><td class="mono">4</td><td><code>plan --check</code> found changes pending.</td></tr>
      </tbody>
    </table></div>
  </div>
</div>
HTML
  page_end
} >"$site/guide.html"

echo "docs built in $site"
