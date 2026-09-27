#!/bin/sh
# Tests for tools/installer/qhora-stock-fallback.sh with a mocked stock env.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
exec "$root/tools/build/run.sh" sh -c '
T=$(mktemp -d); cd $T
cat > fw_printenv <<"EOF"
#!/bin/sh
[ "$1" = -n ] && { v=$(sed -n "s/^$2=//p" $ENVF); [ -n "$v" ] || exit 1; echo "$v"; }
EOF
cat > fw_setenv <<"EOF"
#!/bin/sh
while IFS= read -r line; do k=${line%% *}; v=${line#* }; [ "$v" = "$k" ] && v=
  grep -v "^$k=" $ENVF > $ENVF.n || true; [ -n "$v" ] && echo "$k=$v" >> $ENVF.n; mv $ENVF.n $ENVF; done
EOF
chmod +x fw_printenv fw_setenv; export PATH=$T:$PATH QH_TEST=1 ENVF=$T/env
S=/work/tools/installer/qhora-stock-fallback.sh
pass=0; fail=0
t() { if eval "$2"; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1"; cat env; fi; }
printf "bootcmd=aq_load_fw 0; aq_load_fw 8; bootipq\nBMAC=245EBE000000\nQSN=Q000\n" > env; cp env env.orig
sh $S >/dev/null
t "dry run writes nothing" "cmp -s env env.orig"
sh $S --yes >/dev/null
t "existing bootcmd kept, fallback appended" "grep -q \"^bootcmd=aq_load_fw 0; aq_load_fw 8; bootipq; run qh_fallback\$\" env"
t "qh_fallback set" "grep -q \"^qh_fallback=echo qh: stock boot failed\" env"
t "inventory untouched" "grep -q ^BMAC=245EBE000000\$ env && grep -q ^QSN=Q000\$ env"
t "second run is a no-op" "sh $S --yes | grep -q \"already set\""
sh $S --remove --yes >/dev/null
t "remove restores bootcmd, drops qh_ vars" "[ \"\$(sed -n s/^bootcmd=//p env)\" = \"aq_load_fw 0; aq_load_fw 8; bootipq\" ] && ! grep -q qh_ env"
printf "bootcmd=run something_else\n" > env
t "refuses an unexpected bootcmd" "sh $S --yes 2>&1 | grep -q \"not touching it\""
echo "$pass passed, $fail failed"; [ $fail = 0 ]
' </dev/null
