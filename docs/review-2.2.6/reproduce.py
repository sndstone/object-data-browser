import base64, importlib.util, io, json, subprocess, sys, tempfile, threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('review_engine',root/'engines/python/src/main.py')
m=importlib.util.module_from_spec(spec); sys.modules[spec.name]=m; spec.loader.exec_module(m)
m._emit_transfer_event=lambda *a,**k:None
profile={'endpointUrl':'http://127.0.0.1:1','accessKey':'fixture','secretKey':'fixture'}
class Client:
    def __init__(self, objects, short=False, fail=False): self.objects=objects; self.short=short; self.fail=fail
    def head_object(self,**k):return {'ContentLength':len(self.objects[k['Key']])}
    def get_object(self,**k):
        if self.fail: raise RuntimeError('fixture read failure')
        data=self.objects[k['Key']]
        if 'Range' in k:
            start,end=map(int,k['Range'][6:].split('-'));data=data[start:end+1]
        if self.short:data=data[:3]
        return {'Body':io.BytesIO(data)}
results=[]
with tempfile.TemporaryDirectory(prefix='odb-review-') as directory:
    dest=Path(directory)
    def run(client,keys,threshold=32):
        m._build_client=lambda _:client
        return m._run_transfer(m._start_download,{'profile':profile,'bucketName':'fixture','keys':keys,'destinationPath':directory,'multipartThresholdMiB':threshold,'multipartChunkMiB':1})
    job=run(Client({'a/report.txt':b'FIRST','b/report.txt':b'SECOND'}),['a/report.txt','b/report.txt'])
    results.append({'finding':'B02 collision','jobStatus':job['status'],'files':[p.name for p in dest.iterdir()],'reportContents':(dest/'report.txt').read_text()})
    (dest/'existing.txt').write_bytes(b'ORIGINAL LOCAL FILE')
    try:run(Client({'existing.txt':b'NEW'},fail=True),['existing.txt'])
    except RuntimeError:pass
    results.append({'finding':'B02 failure truncates existing destination','remainingBytes':(dest/'existing.txt').stat().st_size})
    job=run(Client({'range.bin':b'x'*(1024*1024)},short=True),['range.bin'],1)
    data=(dest/'range.bin').read_bytes()
    results.append({'finding':'B03 truncated range','jobStatus':job['status'],'reportedBytes':job['bytesTransferred'],'actualPayloadBytes':len(data.rstrip(b'\0')),'fileSize':len(data)})
class Handler(BaseHTTPRequestHandler):
    calls=[]
    def log_message(self,*args):pass
    def reply(self,code,pending=False):
        self.calls.append(self.command+' '+self.path)
        self.send_response(code)
        if pending:self.send_header('x-ms-copy-status','pending');self.send_header('x-ms-copy-id','fixture-copy')
        self.send_header('Content-Length','0');self.end_headers()
    def do_PUT(self):self.rfile.read(int(self.headers.get('Content-Length',0)));self.reply(202,True)
    def do_HEAD(self):self.reply(200,True)
    def do_DELETE(self):self.reply(202)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
try:
    request={'requestId':'review-pending-copy','method':'moveObject','params':{'profile':{'endpointType':'azureBlob','endpointUrl':f'http://127.0.0.1:{server.server_port}','accessKey':'fixture','secretKey':base64.b64encode(b'fixture-key').decode()},'sourceBucketName':'source','sourceKey':'important.txt','destinationBucketName':'dest','destinationKey':'important.txt'}}
    proc=subprocess.run([str(root/'.tmp/review-226-go-engine')],input=json.dumps(request)+'\n',text=True,capture_output=True,timeout=20,check=True)
    replies=[json.loads(line) for line in proc.stdout.splitlines()]
    reply=next(x for x in replies if x.get('requestId')=='review-pending-copy')
    results.append({'finding':'B01 Go Azure pending copy','ok':reply.get('ok'),'headPolls':sum(c.startswith('HEAD ') for c in Handler.calls),'sourceDeleteSent':any(c.startswith('DELETE ') for c in Handler.calls),'allCopyResponses':'pending'})
finally:server.shutdown();server.server_close();thread.join()
print(json.dumps(results,indent=2))

