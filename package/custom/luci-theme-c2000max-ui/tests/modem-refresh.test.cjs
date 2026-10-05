const assert=require('node:assert/strict'),D=require('../htdocs/luci-static/c2000max-ui/data.js');
const start=1700000000000;
const e=(key,value,extra_info)=>({key,value,extra_info});
const packet=(entries,sample,age=0,kind='cell')=>({section:'2_1',sources:[{kind,sample,age,entries}]});
let snapshot=D.modemSnapshot({},packet([e('network_mode','NR5G-SA Mode'),e('Band','78'),e('Band (CA)','78','CA-NR'),e('RSRP','-93'),e('SINR','9'),e('MCC','460'),e('MNC','01')],100),start);
snapshot=D.modemSnapshot(snapshot,packet([e('name','MT5700M-CN'),e('revision','firmware'),e('temperature','52 °C')],100,0,'base'),start);
assert.equal(D.modem(snapshot,{}, {},start).rsrp,-93);
assert.equal(D.modem(snapshot,{}, {},start).carriers,2);
// Empty/partial refreshes do not blank earlier fields or renew their age.
snapshot=D.modemSnapshot(snapshot,packet([],101),start+15000);
snapshot=D.modemSnapshot(snapshot,packet([e('network_mode','NR5G-SA Mode'),e('SINR','255')],102),start+30000);
assert.equal(D.modem(snapshot,{}, {},start+30000).rsrp,-93);
assert.equal(D.modem(snapshot,{}, {},start+30000).sinr,9);
assert.equal(D.modem(snapshot,{}, {},start+30000).temperature,52);
const expired=D.modem(snapshot,{}, {},start+121000);
assert.equal(expired.rsrp,null);assert.equal(expired.sinr,null);assert.equal(expired.temperature,null);
assert.equal(expired.model,'MT5700M-CN');
// A fresh primary band authoritatively replaces the aggregation snapshot.
snapshot=D.modemSnapshot(snapshot,packet([e('network_mode','NR5G-SA Mode'),e('Band','78'),e('RSRP','-95')],103),start+45000);
assert.equal(D.modem(snapshot,{}, {},start+45000).carriers,1);
// Delayed older replies cannot roll back the current cell or carrier list.
snapshot=D.modemSnapshot(snapshot,packet([e('network_mode','LTE Mode'),e('Band','3'),e('RSRP','-60')],99),start+46000);
assert.equal(D.modem(snapshot,{}, {},start+46000).mode,'NR5G-SA Mode');
assert.equal(D.modem(snapshot,{}, {},start+46000).rsrp,-95);
// A RAT change clears old NR readings, rather than borrowing LTE/NR fields.
snapshot=D.modemSnapshot(snapshot,packet([e('network_mode','LTE Mode'),e('Band','3')],104),start+60000);
assert.equal(D.modem(snapshot,{}, {},start+60000).rsrp,null);
assert.equal(D.modem(snapshot,{}, {},start+60000).band,'B3');
snapshot=D.modemSnapshot(snapshot,packet([e('network_mode','No Service')],105),start+75000);
assert.equal(D.modem(snapshot,{}, {},start+75000).status,'unregistered');
assert.equal(D.modem(snapshot,{}, {},start+75000).band,null);
// Identical cache generations cannot extend the sample's original lifetime.
let repeated=D.modemSnapshot({},packet([e('network_mode','NR5G-SA Mode'),e('Band','78'),e('RSRP','-93')],10),start);
repeated=D.modemSnapshot(repeated,packet([e('network_mode','NR5G-SA Mode'),e('Band','78'),e('RSRP','-93')],10),start+100000);
assert.equal(D.modem(repeated,{}, {},start+121000).band,null);
assert.equal(D.modem(repeated,{}, {},start+121000).rsrp,null);
// Switching selected devices does not carry identity or signal across modems.
const switched=D.modemSnapshot(snapshot,{section:'another',sources:[]},start+76000);
assert.equal(D.modem(switched,{}, {},start+76000).model,null);
assert.equal(D.modem({}, {current_slot:'external1',receivedAt:start}, {},start+121000).sim,null);
// A recent complete info snapshot fills a partial cache on first page load.
const complete=[e('network_mode','NR5G-SA Mode'),e('Cell ID','123'),e('Band','78'),e('Band 1','78'),e('RSRP','-93')];
const partial={section:'2_1',sources:[{kind:'cell',age:0,entries:[e('network_mode','NR5G-SA Mode'),e('Cell ID','123'),e('RSRP','-95')]},{kind:'info',age:30,entries:complete}]};
assert.equal(D.modem(partial).band,'n78');assert.equal(D.modem(partial).carriers,2);assert.equal(D.modem(partial).rsrp,-95);
const mismatched={...partial,sources:[{...partial.sources[0],entries:[e('network_mode','LTE Mode'),e('Cell ID','456')]},partial.sources[1]]};
assert.equal(D.modem(mismatched).band,null);assert.equal(D.modem(mismatched).rsrp,null);
const single={...partial,sources:[{...partial.sources[0],entries:[...partial.sources[0].entries,e('Band','78')]},partial.sources[1]]};
assert.equal(D.modem(single).carriers,1,'fallback must not restore a removed secondary carrier');
console.log('PASS: partial failures, sample expiry, aggregation changes, delayed replies, RAT changes and device isolation');
