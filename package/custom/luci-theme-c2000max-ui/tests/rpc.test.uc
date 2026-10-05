// Exercise the deployed ucode handler itself, not a JavaScript copy.
import { stat, writefile, unlink } from 'fs';
const base=ARGV[0];
const api=loadfile(base+'/root/usr/share/rpcd/ucode/c2000max-ui', { raw_mode: true })();
for(let section in ['', '../etc/passwd', 'modem1;reboot', 'a/b', null, 123]) {
 const result=api['c2000max.ui'].modem.call({args:{section}});
 if(result.error!='invalid_section')die('Expected rejection: '+section+'\n');
}
const missing=api['c2000max.ui'].modem.call({args:{section:'theme_test_missing_modem'}});
if(!missing.cache_only || length(missing.sources))die('Missing modem must return an empty snapshot\n');
const section='c2000ui_test_'+time();
const file='/tmp/cache_cell_info_'+section;
if(stat(file))die('Test cache already exists\n');
writefile(file, '{"modem_info":[{"key":"RSRP","value":"-82"}]}');
const cached=api['c2000max.ui'].modem.call({args:{section}});
unlink(file);
if(length(cached.sources)!=1 || cached.sources[0].entries[0].value!='-82' || cached.sources[0].age>5)
 die('Valid cache did not round-trip with correct age\n');
writefile(file, '{broken');
const broken=api['c2000max.ui'].modem.call({args:{section}});
unlink(file);
if(length(broken.sources))die('Malformed cache was not ignored\n');
print('PASS: deployed rpcd handler validates sections, parses cache with age and skips missing/malformed data.\n');
