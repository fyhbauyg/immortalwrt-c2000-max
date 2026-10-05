from pathlib import Path
import subprocess,tempfile,os,json,shutil
theme=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp); cache=root/'cache'; cache.mkdir()
    base=root/'bundled'; shutil.copytree(theme/'htdocs/luci-static/c2000max-ui/wallpaper',base)
    script=root/'cgi.sh'
    script.write_text((theme/'root/www/cgi-bin/c2000max-wallpaper').read_text().replace('/www/luci-static/c2000max-ui/wallpaper',str(base)).replace('/tmp/c2000max-ui',str(cache)))
    def call(query='',method='GET'):
        data=subprocess.check_output(['sh',str(script)],env={**os.environ,'QUERY_STRING':query,'REQUEST_METHOD':method})
        return data.split(b'\r\n\r\n',1)
    head,data=call(); assert data==(base/'default.jpg').read_bytes() and b'image/jpeg' in head
    head,data=call('info'); assert json.loads(data)['displayDate']=='2026-09-26' and b'no-store' in head
    assert call('', 'HEAD')[1]==b'' and call('info','HEAD')[1]==b''
    (cache/'bing.jpg').write_bytes(b'cached jpeg')
    assert call()[1]==(base/'default.jpg').read_bytes(), 'incomplete cache must retain fallback'
    (cache/'bing.json').write_text('{"date":"20260927","copyright":"test"}')
    assert call()[1]==b'cached jpeg' and json.loads(call('info')[1])['date']=='20260927'
    assert call('../../etc/shadow')[1]==b'cached jpeg','query must not select arbitrary files'
print('PASS: CGI offline fallback, cache pair, metadata, HEAD and fixed paths')
