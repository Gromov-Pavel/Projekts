import test from 'node:test';
import assert from 'node:assert/strict';
import {score, shots, validate, latest, duel, csv, demo} from './dist/core.mjs';
test('Minor/Major points, penalties, zero floor and unfinished HF',()=>{
 const a={a:4,c:2,d:1,m:1,ns:0,procedures:0,time:10,complete:true,power:'Minor'};
 assert.deepEqual(score(a),{points:17,hf:1.7});assert.deepEqual(score({...a,power:'Major'}),{points:20,hf:2});
 assert.equal(score({...a,m:100}).points,0);assert.equal(score({...a,complete:false}).hf,null);
 assert.equal(score({...a,m:0,ns:1,procedures:1}).points,7);
});
test('strictly increasing positive shot timestamps',()=>{
 assert.deepEqual(shots('1.2 1.55;2.4'),[1.2,1.55,2.4]);assert.deepEqual(shots(''),[]);
 for(const value of ['0 1','1 1','2 1','1 NaN','-2','Infinity'])assert.throws(()=>shots(value));
});
test('validated complete data, IDs, bounds, reference and timestamps',()=>{
 const d=demo();assert.equal(validate(d),d);
 const bad=change=>{const v=structuredClone(d);change(v);assert.throws(()=>validate(v));};
 bad(v=>v.version=2);bad(v=>v.shooters.push(v.shooters[0]));bad(v=>v.attempts.push(v.attempts[0]));bad(v=>v.attempts[0].shooterId='missing');bad(v=>v.attempts[0].time=0);bad(v=>v.attempts[0].a=.5);bad(v=>v.attempts[0].shots=[1,1]);bad(v=>v.attempts[0].shots=[900]);bad(v=>v.attempts[0].createdAt=1e100);bad(v=>v.attempts[0].complete='true');
 assert.deepEqual(JSON.parse(JSON.stringify(validate(d))),d);
});
test('compare up to ten latest attempts for the same exercise',()=>{
 const d=demo(),ids=d.shooters.map(s=>s.id);assert.equal(latest(d,'El Presidente',ids).length,10);
 assert.throws(()=>latest(d,'El Presidente',[...ids,'extra']));assert.equal(latest(d,'unknown',ids).length,0);
 const next={...d.attempts[0],id:'next',createdAt:Date.now()};d.attempts.push(next);assert.equal(latest(d,'El Presidente',[ids[0]])[0],next);
});
test('duel rejects same shooter and unfinished attempts, handles tie',()=>{
 const [a,b]=demo().attempts;assert.equal(duel(a,b),a.shooterId);assert.match(duel(a,a),/разных/);assert.match(duel(a,{...b,complete:false}),/не определён/);assert.match(duel(a),/нужны/);assert.equal(duel(a,{...a,shooterId:b.shooterId}),'Ничья');
});
test('CSV exports headers, quotes, BOM and neutralizes spreadsheet formulas',()=>{
 const d=demo();d.shooters[0].name=' =HYPERLINK("evil")';d.attempts[0].exercise='@SUM(1)';
 const out=csv(d);assert.ok(out.startsWith('\uFEFF'));assert.ok(out.includes("\"' =HYPERLINK(\"\"evil\"\")\""));assert.ok(out.includes("\"'@SUM(1)\""));assert.ok(out.includes('Hit factor'));assert.ok(out.includes('\r\n'));
});
