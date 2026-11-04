#!/bin/bash
# test/run.sh - end-to-end test on a throwaway fixture. Needs only bash, coreutils,
# findutils, zip/unzip and lua. Usage: test/run.sh [workdir]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/romsort-test.XXXXXX")}
rm -rf "$work"; mkdir -p "$work"
R=$work/roms
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "ok   $*"; }

# ---- fixture ---------------------------------------------------------------
lb=$R/F/LaunchBox
mkdir -p "$lb/Games/Nintendo Game Boy/Packs" "$lb/Games/Sony Playstation/Disc Game" \
         "$lb/Data/Platforms" "$lb/Images/Nintendo Game Boy/Box - Front" \
         "$R/P/Games/Sony PSP" "$R/F/cards/c1/GB/Imgs" "$R/F/cards/c1/MAME" "$work/dats/no-intro"
printf 'TETRIS-ROM-DATA-%.0s' {1..64} > "$lb/Games/Nintendo Game Boy/tetris final.gb"
printf 'ZELDA-ROM-DATA--%.0s' {1..64} > "$work/zelda.gb"
(cd "$work" && if command -v zip >/dev/null; then zip -q -j "$lb/Games/Nintendo Game Boy/links awakening.zip" zelda.gb; else python3 -m zipfile -c "$lb/Games/Nintendo Game Boy/links awakening.zip" zelda.gb; fi)
printf 'HOMEBREW%.0s' {1..10} > "$lb/Games/Nintendo Game Boy/my hack.gb"
cp "$lb/Games/Nintendo Game Boy/tetris final.gb" "$lb/Games/Nintendo Game Boy/Packs/tetris copy.gb"
printf 'TRACK' > "$lb/Games/Sony Playstation/Disc Game/game (track 1).bin"
printf 'FILE "game (track 1).bin" BINARY\n' > "$lb/Games/Sony Playstation/Disc Game/game.cue"
printf 'PSPISO' > "$R/P/Games/Sony PSP/Loco.iso"
printf 'boxart' > "$lb/Images/Nintendo Game Boy/Box - Front/Tetris-01.png"
printf '<Settings>x</Settings>' > "$lb/Data/Settings.xml"
cp "$lb/Games/Nintendo Game Boy/tetris final.gb" "$R/F/cards/c1/GB/Tetris.gb"   # dup of LB copy
printf 'UNKNOWN-GB%.0s' {1..8} > "$R/F/cards/c1/GB/mystery.gb"
printf 'thumb' > "$R/F/cards/c1/GB/Imgs/mystery.png"
printf 'arcade' > "$R/F/cards/c1/MAME/sf2.zip"
for c in c1 c2; do                     # the same set in a per-game folder on two cards
  mkdir -p "$R/F/cards/$c/MAME/000 Final Fight"; printf 'ffight-set' > "$R/F/cards/$c/MAME/000 Final Fight/ffight.zip"
done

t_sha=$(sha1sum < "$lb/Games/Nintendo Game Boy/tetris final.gb" | cut -c1-40 | tr a-f A-F)
z_crc=$(unzip -lv "$lb/Games/Nintendo Game Boy/links awakening.zip" | awk '/zelda.gb/{print $7}' | tr a-f A-F)
z_size=$(stat -c %s "$work/zelda.gb")
cat > "$work/dats/no-intro/Nintendo - Game Boy.dat" <<EOF
clrmamepro (
	name "Nintendo - Game Boy"
)

game (
	name "Tetris (World) (Rev 1)"
	rom ( name "Tetris (World) (Rev 1).gb" size 1024 crc 00000000 sha1 $t_sha )
)
game (
	name "Legend of Zelda, The - Link's Awakening (USA, Europe)"
	rom ( name "Legend of Zelda, The - Link's Awakening (USA, Europe).gb" size $z_size crc $z_crc sha1 0000000000000000000000000000000000000000 )
)
EOF

cat > "$lb/Data/Platforms/Nintendo Game Boy.xml" <<'EOF'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Game>
    <ApplicationPath>Games\Nintendo Game Boy\tetris final.gb</ApplicationPath>
    <ID>1</ID>
    <Title>Tetris</Title>
  </Game>
  <Game>
    <ApplicationPath>J:\Games\Nintendo Game Boy\LINKS AWAKENING.zip</ApplicationPath>
    <ID>2</ID>
    <Title>Link's Awakening &amp; Friends</Title>
  </Game>
  <Game>
    <ApplicationPath>Games\Nintendo Game Boy\my hack.gb</ApplicationPath>
    <ID>3</ID>
  </Game>
  <Game>
    <ApplicationPath>J:\Games\Nintendo DS\gone forever.nds</ApplicationPath>
    <ID>4</ID>
  </Game>
  <AdditionalApplication>
    <ApplicationPath>Games\Nintendo Game Boy\Packs\tetris copy.gb</ApplicationPath>
  </AdditionalApplication>
</LaunchBox>
EOF
cat > "$lb/Data/Platforms/Sony PSP.xml" <<'EOF'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Game>
    <ApplicationPath>P:\Games\Sony PSP\Loco.iso</ApplicationPath>
    <ID>5</ID>
  </Game>
  <Game>
    <ApplicationPath>Games\Sony Playstation\Disc Game\game.cue</ApplicationPath>
    <ID>6</ID>
  </Game>
</LaunchBox>
EOF
cat > "$lb/Data/Platforms.xml" <<'EOF'
<?xml version="1.0" standalone="yes"?>
<LaunchBox>
  <Platform>
    <Name>Sony PSP</Name>
    <Folder>P:\Games\Sony PSP</Folder>
  </Platform>
</LaunchBox>
EOF

cat > "$work/config.lua" <<EOF
local C = dofile('$here/config.lua')
C.roms = '$R'
C.dats = '$work/dats'
C.out = '$R/sorted/LaunchBox'
C.state = '$R/sorted/.romsort'
C.launchbox = '$lb'
C.drives = { J = { '$lb' }, P = { '$R/P' } }
C.sources = {
  { label = 'LB', root = '$lb/Games', layout = 'launchbox' },
  { label = 'P', root = '$R/P/Games', layout = 'launchbox' },
  { label = 'c1', root = '$R/F/cards/c1', layout = 'folders' },
  { label = 'c2', root = '$R/F/cards/c2', layout = 'folders' },
}
C.jobs = 2
return C
EOF
before=$(cd "$R" && find F P -type f -exec sha1sum {} + | sort)

# ---- run -------------------------------------------------------------------
lua=${LUA:-$(command -v luajit || command -v lua || command -v lua5.4 || command -v lua5.1)}
rs() { "$lua" "$here/romsort.lua" "$@" --config "$work/config.lua"; }
out=$R/sorted/LaunchBox
G="$out/Games/Nintendo Game Boy"

rs build > "$work/build1.log" || { cat "$work/build1.log"; fail "first build"; }
pass "first build and check pass"

[ "$G/Tetris (World) (Rev 1).gb" -ef "$lb/Games/Nintendo Game Boy/tetris final.gb" ] || fail "tetris not renamed as hardlink"
[ -f "$G/Legend of Zelda, The - Link's Awakening (USA, Europe).zip" ] || fail "zip not renamed by member CRC"
[ -f "$G/my hack.gb" ] || fail "unmatched LaunchBox file kept by name"
[ -f "$G/Packs/tetris copy.gb" ] || fail "subfolder file kept at its path"
[ -f "$out/Games/Sony Playstation/Disc Game/game (track 1).bin" ] || fail "disc track kept"
[ -f "$out/Games/Sony PSP/Loco.iso" ] || fail "P: drive file adopted into Games"
[ -f "$out/Images/Nintendo Game Boy/Box - Front/Tetris-01.png" ] || fail "images mirrored"
[ ! "$out/Data/Settings.xml" -ef "$lb/Data/Settings.xml" ] && [ -f "$out/Data/Settings.xml" ] || fail "Data copied, not linked"
[ -f "$out/Games/Nintendo Game Boy/Unverified/mystery.gb" ] || fail "card unmatched -> Unverified"
[ ! -e "$out/Games/Nintendo Game Boy/Unverified/Imgs/mystery.png" ] || fail "card thumbnails skipped"
[ -f "$out/Games/Arcade/sf2.zip" ] || fail "arcade kept by set name"
[ "$(find "$out/Games" -name 'Tetris*' | wc -l)" = 1 ] || fail "card duplicate deduped"
[ "$(find "$out/Games/Arcade" -name 'ffight*' | wc -l)" = 1 ] || fail "same set on two cards placed once"
! grep -q 'conflict=' "$work/build1.log" || fail "no conflicting ops in the plan"
pass "placement rules"

if command -v nvim >/dev/null 2>&1; then
  "$here/romsort" ui --print --config "$work/config.lua" > "$work/ui.txt" 2>&1 || { cat "$work/ui.txt"; fail "dashboard renders"; }
  grep -q 'check PASSED' "$work/ui.txt" && grep -q 'renamed to DAT name' "$work/ui.txt" || { cat "$work/ui.txt"; fail "dashboard shows check and totals"; }
  pass "neovim dashboard renders"
fi

x="$out/Data/Platforms/Nintendo Game Boy.xml"
grep -q '<ApplicationPath>Games\\Nintendo Game Boy\\Tetris (World) (Rev 1).gb</ApplicationPath>' "$x" || fail "tetris path rewritten"
grep -q "Link's Awakening (USA, Europe).zip</ApplicationPath>" "$x" || fail "J: path rewritten relative"
grep -q '<ApplicationPath>J:\\Games\\Nintendo DS\\gone forever.nds</ApplicationPath>' "$x" || fail "missing path left untouched"
grep -q '<Title>Link&apos;s Awakening &amp; Friends</Title>\|<Title>Link'"'"'s Awakening &amp; Friends</Title>' "$x" || fail "non-path XML preserved"
grep -q '<Folder>Games\\Sony PSP</Folder>' "$out/Data/Platforms.xml" || fail "platform folder rewritten"
pass "LaunchBox XML rewritten, everything else preserved"

after=$(cd "$R" && find F P -type f -exec sha1sum {} + | sort)
[ "$before" = "$after" ] || fail "a source file changed"
pass "sources untouched"

rs build > "$work/build2.log" || fail "second build"
grep -q 'applied: $' "$work/build2.log" || { cat "$work/build2.log"; fail "rebuild not idempotent"; }
pass "rebuild is idempotent"

echo '<!-- edited in LaunchBox -->' >> "$x"
rs build > "$work/build3.log" || true
grep -q 'edited in LaunchBox' "$x" || fail "user edit to generated XML clobbered"
[ -f "$x.romsort-new" ] || fail ".romsort-new written beside edited XML"
pass "edits made in the sorted library are kept"

echo "all tests passed ($work)"
