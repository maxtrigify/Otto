import {build} from 'esbuild';
import {mkdir,copyFile} from 'node:fs/promises';
await mkdir('dist',{recursive:true});
await build({entryPoints:['web/app.mjs'],bundle:true,format:'esm',outfile:'dist/app.js',target:'safari17',minify:true,sourcemap:false});
for(const name of ['index.html','style.css'])await copyFile('web/'+name,'dist/'+name);
