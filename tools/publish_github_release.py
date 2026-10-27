"""Publish immutable, locally tested packages using a scoped Actions token.

Git/SSH supplies the files. GitHub Actions supplies the short-lived token;
no PAT, OAuth credential, private key or local environment file is uploaded.
"""
import argparse
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile


def digest(path):
    with path.open('rb') as data:
        return hashlib.file_digest(data,'sha256').hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,request,fp,code,msg,headers,newurl):
        raise RuntimeError('Authenticated API redirects are not permitted')


class GitHub:
    def __init__(self,repo,token):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo):
            raise ValueError('Invalid repository')
        self.repo=repo
        self.headers={'Accept':'application/vnd.github+json','Authorization':f'Bearer {token}',
            'User-Agent':'FPGA-ETH-IMG-release','X-GitHub-Api-Version':'2026-03-10'}
        self.opener=urllib.request.build_opener(NoRedirect())

    def call(self,method,path,*,body=None,file=None,missing_ok=False):
        url=path if path.startswith('https://') else 'https://api.github.com'+path
        parsed=urllib.parse.urlsplit(url)
        if parsed.scheme!='https' or parsed.hostname not in ('api.github.com','uploads.github.com'):
            raise ValueError('Untrusted API endpoint')
        if not parsed.path.startswith(f'/repos/{self.repo}/'):
            raise ValueError('API request does not target the selected repository')
        headers=dict(self.headers)
        if file is not None:
            data=file.read_bytes()
            headers['Content-Type']=mimetypes.guess_type(file.name)[0] or 'application/octet-stream'
        elif body is not None:
            data=json.dumps(body,ensure_ascii=False).encode('utf-8')
            headers['Content-Type']='application/json'
        else:
            data=None
        request=urllib.request.Request(url,data=data,headers=headers,method=method)
        try:
            with self.opener.open(request,timeout=300) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing_ok and error.code==404:return None
            try:message=json.loads(error.read()).get('message','')
            except (ValueError,AttributeError):message='API request failed'
            raise RuntimeError(f'GitHub HTTP {error.code}: {message}') from None


def prepare(assets_dir,out,tag,commit):
    record=json.loads((assets_dir/'publication.json').read_text(encoding='utf-8'))
    assert record['tag']==tag and record['source_commit']==commit,'Release commit mismatch'
    assert re.fullmatch(r'[0-9a-f]{40}',commit),'Invalid source commit'
    for item in record['packages']:
        name=item['name']
        assert Path(name).name==name and len(name)<150,'Unsafe package name'
        path=assets_dir/name
        assert digest(path)==item['sha256'],f'Package hash mismatch: {name}'
    runtime=assets_dir/f'FPGA_ETH_IMG-ZU4EV-{tag}.zip'
    source=assets_dir/f'FPGA_ETH_IMG-ZU4EV-{tag}-source.zip'
    with zipfile.ZipFile(runtime) as archive:
        assert archive.testzip() is None,'Runtime archive CRC mismatch'
        prefix=f'FPGA_ETH_IMG-ZU4EV-{tag}/'
        manifest=json.loads(archive.read(prefix+'release_manifest.json'))
        assert manifest['tag']==tag
        for name in ['ETH_Image_ZU4EV.exe','eth_img.bit','release_manifest.json']:
            (out/name).write_bytes(archive.read(prefix+name))
        for name,key in [('ETH_Image_ZU4EV.exe','executable_sha256'),('eth_img.bit','bitstream_sha256')]:
            assert digest(out/name)==record[key],f'Tested binary hash mismatch: {name}'
        expected_source=manifest['source_archive']['sha256']
        assert digest(source)==expected_source,'Source snapshot differs from runtime manifest'
    with zipfile.ZipFile(source) as archive:
        assert archive.testzip() is None,'Source archive CRC mismatch'
    files=[runtime,source,out/'ETH_Image_ZU4EV.exe',out/'eth_img.bit',out/'release_manifest.json']
    license_path=Path(__file__).resolve().parents[1]/'LICENSE'
    if license_path.exists():files.append(license_path)
    sums=out/'SHA256SUMS.txt'
    sums.write_text(''.join(f'{digest(path)}  {path.name}\n' for path in files),encoding='utf-8')
    files.append(sums)
    return files,record


def publish(api,files,record,body):
    prefix=f'/repos/{api.repo}'
    tag=record['tag']
    release=api.call('GET',prefix+'/releases/tags/'+urllib.parse.quote(tag,safe=''),missing_ok=True)
    if release is None:
        release=api.call('POST',prefix+'/releases',body=dict(tag_name=tag,
            target_commitish=record['source_commit'],name=f'{tag} · ZU4EV 720p25 Sobel',
            body=body,draft=True,prerelease=False))
    assert release['tag_name']==tag
    existing={item['name']:item for item in api.call('GET',prefix+f"/releases/{release['id']}/assets?per_page=100")}
    upload=release['upload_url'].split('{',1)[0]
    for path in files:
        expected='sha256:'+digest(path)
        if path.name in existing:
            item=existing[path.name]
            assert item['state']=='uploaded' and item['size']==path.stat().st_size,item['name']
            assert item.get('digest')==expected,f'Existing asset has a different or unavailable digest: {path.name}'
            print('Verified existing asset:',path.name,flush=True)
            continue
        item=api.call('POST',upload+'?name='+urllib.parse.quote(path.name,safe=''),file=path)
        assert item['state']=='uploaded' and item['size']==path.stat().st_size,path.name
        assert item.get('digest')==expected,f'Uploaded asset digest mismatch: {path.name}'
        print('Uploaded and verified:',path.name,flush=True)
    # Reveal the release only after every expected asset has been verified.
    release=api.call('PATCH',prefix+f"/releases/{release['id']}",body=dict(draft=False,make_latest='true'))
    assert not release['draft']
    print('Published:',release['html_url'],flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets-dir',type=Path,required=True)
    parser.add_argument('--tag',required=True)
    parser.add_argument('--commit',required=True)
    parser.add_argument('--dry-run',action='store_true')
    args=parser.parse_args()
    assert re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+',args.tag)
    with tempfile.TemporaryDirectory(prefix='fpga-release-') as temporary:
        files,record=prepare(args.assets_dir,Path(temporary),args.tag,args.commit)
        for path in files:print(json.dumps(dict(name=path.name,bytes=path.stat().st_size,sha256=digest(path))))
        if args.dry_run:
            print('PASS release preparation; no API mutation performed')
            return
        repo=os.environ['GITHUB_REPOSITORY']
        token=os.environ['GITHUB_TOKEN']
        body=(args.assets_dir/'release_notes.md').read_text(encoding='utf-8')
        publish(GitHub(repo,token),files,record,body)

if __name__=='__main__':main()
