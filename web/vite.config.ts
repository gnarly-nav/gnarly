import {defineConfig,loadEnv} from 'vite';
import react from '@vitejs/plugin-react';
import {readSignedTarget} from './signedProxy.mjs';

function proxySigned(req,res,bucket){
  const source=req.originalUrl||req.url||'';
  const query=source.includes('?')?source.slice(source.indexOf('?')):'';
  const target=readSignedTarget(new URL('http://localhost/'+query).searchParams.get('url'),bucket);
  if(!target){res.writeHead(400).end('Invalid signed URL');return}
  fetch(target).then(async upstream=>{
    res.writeHead(upstream.status,{'Content-Type':upstream.headers.get('content-type')||'application/octet-stream','Cache-Control':'private, max-age=60'});
    res.end(Buffer.from(await upstream.arrayBuffer()));
  }).catch(()=>{res.writeHead(502).end('Storage request failed')});
}

export default defineConfig(({mode})=>{
  const env=loadEnv(mode,process.cwd(),'VITE_');
  const buckets=[env.VITE_GNARLY_BUCKET||'gnarly-data-402275401617-us-east-1',env.VITE_FIREBASE_STORAGE_BUCKET].filter(Boolean);
  const legacy=env.VITE_FIREBASE_STORAGE_BUCKET;
  const prefix=legacy?'/__firebase_storage/v0/b/'+encodeURIComponent(legacy)+'/o/':'';
  return {
    base:env.VITE_BASE||'/',
    plugins:[react(),{
      name:'gnarly-signed-proxy',
      configureServer(server){server.middlewares.use('/__signed',(req,res)=>proxySigned(req,res,buckets));},
      configurePreviewServer(server){server.middlewares.use('/__signed',(req,res)=>proxySigned(req,res,buckets));},
    }],
    server:{proxy:prefix?{[prefix]:{target:'https://firebasestorage.googleapis.com',changeOrigin:true,rewrite:path=>path.replace(/^\/__firebase_storage/,'')}}:{}},
  };
});
