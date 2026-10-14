/** Headless browser-WASI binding tradeoffs; no server, GUI or external text.
 * Run after tools/small_model_eval.py. Compares the same 384 capture traces
 * against native before_fix, and reports WASM linear-memory high water.
 * Native timers exclude JS; here key+state includes the binding/JSON work.
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { WASI } from '../site/node_modules/@bjorn3/browser_wasi_shim/dist/index.js';
import { MisstypeWasm } from '../packages/misstype-wasm/src/index.js';

const dir=path.resolve(process.argv[2] || '.cache/wordlm/small-eval');
const cases=JSON.parse(fs.readFileSync(path.join(dir,'wasm-cases.json')));
const resources=path.resolve('dist/MisstypeIME.app/Contents/Resources');
const lex=fs.readFileSync(path.join(resources,'lexicon.tsv'),'utf8')+'\n'+fs.readFileSync(path.join(resources,'local_phrases.tsv'),'utf8');
const tones=fs.readFileSync(path.join(resources,'toneless.tsv'),'utf8');
const wasm=fs.readFileSync('core-zig/zig-out/wasm/misstype.wasm');
const sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
const punctuation={'，':['Comma','<'], '。':['Period','>'], '？':['Slash','?'], '！':['Digit1','!'], '：':['Semicolon',':'], '；':['Semicolon',':']};
const physical={ '-':'Minus','=':'Equal','[':'BracketLeft',']':'BracketRight','\\':'Backslash',';':'Semicolon',"'":'Quote',',':'Comma','.':'Period','/':'Slash','`':'Backquote'};
const tiny=process.argv.includes("--tiny-rerank");
const profiles=tiny?{default:path.join(resources,"homophone.bin"),none:null,pmi50k:".cache/wordlm/pmi-tiny/pairs-50000.bin",pmi100k:".cache/wordlm/pmi-tiny/pairs-100000.bin"}:{default:path.join(resources,'homophone.bin'),'50k':'.cache/wordlm/sparse/pairs-50000.bin','200k':'.cache/wordlm/sparse/pairs-200000.bin'};
const result={wasm_sha256:sha(wasm),lexicon_sha256:sha(lex),toneless_sha256:sha(tones),cases:cases.length,
 measurement:'Node headless browser-WASI; key + state includes JS and JSON; linear-memory high water is not browser RSS',profiles:{}};
for(const includeEnglish of [false,true]) for(const [name,modelPath] of Object.entries(profiles)) {
 const runName=`${includeEnglish?'with-english':'Chinese-only'}:${name}`;
 const wasi=new WASI([],[],[]);
 const {instance}=await WebAssembly.instantiate(wasm,{wasi_snapshot_preview1:wasi.wasiImport});wasi.start(instance);
 const api=new MisstypeWasm(instance,wasi);
 const initStarted=performance.now();
 api.init(lex,tones);
 const ChineseLinear=api.memory.buffer.byteLength;
 const ChineseInitMs=performance.now()-initStarted;
 const englishStarted=performance.now();
 if(includeEnglish) api.loadEnglish(fs.readFileSync(path.join(resources,'english.tsv'),'utf8'));
 const EnglishInitMs=includeEnglish?performance.now()-englishStarted:0;
 const before=api.memory.buffer.byteLength;
 const model=modelPath?fs.readFileSync(modelPath):Buffer.alloc(0);
 const started=performance.now();
 const loaded=name==='none'?true:(tiny || name==='default'?api.loadHomophone(model):api.loadWordModel(model,.5));
 if(!loaded)throw new Error(`model refused: ${name}`);
 const loadMs=performance.now()-started;
 const after=api.memory.buffer.byteLength;
 const native=JSON.parse(fs.readFileSync(path.join(dir,`${name}.json`))).cases;
 const times=[];const mismatches=[];
 let stamp=1000;
 for(const item of cases) {
  api.reset();let emitted='';
  for(const ch of item.keys) {
   stamp+=.2;const t=performance.now();
   if(ch==='⌫')api.key('Backspace','',0,0,stamp);
   else if(ch===' ')api.key('Space',' ',0,0,stamp);
   else if(punctuation[ch]) {const [code,text]=punctuation[ch];api.key(code,text,1,0,stamp);}
   else api.key(physical[ch] || (/\d/.test(ch)?`Digit${ch}`:`Key${ch.toUpperCase()}`),ch,0,0,stamp);
   api.state();emitted+=api.takeCommitted();times.push(performance.now()-t);
  }
  const shown=emitted+api.state().preedit;
  if(shown!==native[item.id].shown)mismatches.push({id:item.id,native:native[item.id].shown,wasm:shown});
 }
 times.sort((a,b)=>a-b);
 const row={includeEnglish,Chinese_lexicon_linear_bytes:ChineseLinear,Chinese_init_ms:ChineseInitMs,English_init_ms:EnglishInitMs,model_bytes:model.length,model_sha256:sha(model),before_model_linear_bytes:before,after_model_linear_bytes:after,
  load_linear_growth_bytes:after-before,load_ms:loadMs,after_typing_linear_bytes:api.memory.buffer.byteLength,
  key_events:times.length,mean_ms:times.reduce((a,b)=>a+b,0)/times.length,p95_ms:times[Math.floor(times.length*.95)],
  max_ms:times.at(-1),native_preview_mismatches:mismatches.length,examples:mismatches.slice(0,5)};
 result.profiles[runName]=row;console.log(runName,JSON.stringify(row));
}
fs.writeFileSync(path.join(dir,'wasm-report.json'),JSON.stringify(result,null,2)+'\n');
if(Object.values(result.profiles).some(r=>r.native_preview_mismatches))process.exitCode=1;
