#!/usr/bin/env python3
"""Synthetic V3.9 section 7.12 / 8.10 fixtures; no modem I/O."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'files/usr/share/qmodem/vendor/meig.sh').read_text().replace('source /usr/share/qmodem/generic.sh','')
with tempfile.TemporaryDirectory() as d:
    vendor=Path(d)/'meig.sh'; vendor.write_text(source)
    def run(body):
        pre=r"""
source "$1"
at_port=/dev/mock
pdp_index=3
m_debug() { :; }
add_plain_info_entry() { printf '%s|%s|%s\n' "$1" "$2" "${extra_info:-}"; }
add_bar_info_entry() { add_plain_info_entry "$@"; }
at() { [ "$2" = 'AT^CELLINFO=1' ] || { echo "WRONG QUERY $2" >&2; return 1; }; printf '%s\r\nOK\r\n' "$REPLY"; }
"""
        return subprocess.check_output(['bash','-c',pre+body,'test',str(vendor)],text=True)
    for response,expected in [('1,1,1,0','1'),('1,0,1,1','2'),('0,0,0,0',''),('1,1,1,1',''),('ERROR','')]:
        actual=run("printf '%s\\r\\n' '^SIMSLOT: "+response+"' | meig_parse_sim_slot").strip()
        assert actual==expected,(response,actual)
    lte=['LTE','FDD','460','01','100','42','1','2','3','3','100','1','2','-65','-88','-10','134']
    sa=['5G','TDD','460','01','100','42','3','78','100','30','1','1','2','-65','-81','-9','175']
    nsa=lte+['0']*(29-len(lte))+['-79','-8','89','78','640000','100','321','30']
    nsa[0]='EN-DC'
    for fields,checks in [(lte,['network_mode|LTE Mode|','RSRP|-88|','SINR|13.4|']),
                          (sa,['network_mode|NR5G-SA Mode|','RSRP|-81|','SINR|17.5|']),
                          (nsa,['network_mode|EN-DC Mode|','RSRP|-88|LTE','RSRP|-79|NR5G-NSA','Band|78|NR5G-NSA','Physical Cell ID|321|NR5G-NSA','SINR|8.9|NR5G-NSA'])]:
        fields[0]='"'+fields[0]+'"'
        output=run("REPLY='^CELLINFO: "+','.join(fields)+"'\ncell_info")
        for expected in checks: assert expected in output,(expected,output)
    print('PASS: MeiG SA/LTE/NSA fields, query mode independent of PDP, SIM active flags')
