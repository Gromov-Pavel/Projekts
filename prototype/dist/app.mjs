import {score, shots, validate, latest, duel, csv, demo, MAX_COMPARE} from './core.mjs';
const $ = id => document.getElementById(id);
const KEY = 'pace-training-v1';
let data, selected = [], mode = 'splits', editing = null, storageBlocked = false;
const colors = ['#d94a16','#23759a','#52783c','#8e519c','#b18513','#267b70','#b03c60','#5863a9','#6d573a','#3c555c'];
const patterns = ['','7 3','2 3','10 3 2 3','4 2','12 4','1 4','6 2 1 2','9 2 3 2','3 3'];
const fmt = n => Number(n).toFixed(2);
const name = id => data.shooters.find(s=>s.id === id)?.name ?? 'Неизвестный стрелок';
function node(tag, text, attrs = {}) { const el = document.createElement(tag); if (text != null) el.textContent = text; for (const [k,v] of Object.entries(attrs)) el.setAttribute(k,v); return el; }
function notice(text) { $('notice').textContent = text; }
try { const raw = localStorage.getItem(KEY); data = raw === null ? demo() : validate(JSON.parse(raw)); }
selected = data.shooters.slice(0,10).map(s=>s.id);
function persist() {
  if (storageBlocked) { notice('Изменения находятся только в памяти: сохранение заблокировано после ошибки чтения. Экспортируйте JSON.'); return; }
  try { localStorage.setItem(KEY, JSON.stringify(data)); }
  catch { notice('Браузер не смог сохранить данные. Изменения доступны в этой вкладке; экспортируйте JSON перед её закрытием.'); }
}
function optionSelect(el, items, previous) {
  el.replaceChildren();
  for (const [value,text] of items) el.append(node('option',text,{value}));
  if (items.some(([v])=>v === previous)) el.value = previous;
}
function table(target, heads, rows) {
  const t = node('table'), head = node('thead'), hr = node('tr');
  heads.forEach(h=>hr.append(node('th',h,{scope:'col'}))); head.append(hr); t.append(head);
  const body = node('tbody');
  for (const row of rows) { const tr = node('tr'); row.forEach((value,i)=>tr.append(node('td',value,{class:i?'numeric':''}))); body.append(tr); }
  t.append(body); target.replaceChildren(rows.length ? t : node('p','Пока нет данных. Добавьте стрелка и запишите попытку.',{class:'empty'}));
}
function render() {
  const exercise = $('exercise').value, a = $('duel-a').value, b = $('duel-b').value;
  const exercises = [...new Set(data.attempts.map(a=>a.exercise))];
  optionSelect($('exercise'),exercises.map(v=>[v,v]),exercise);
  if (!exercises.length) $('exercise').append(node('option','Нет упражнений',{value:''}));
  const people = data.shooters.map(s=>[s.id,s.name]);
  optionSelect($('duel-a'),people,a); optionSelect($('duel-b'),people,b || people[1]?.[0]);
  optionSelect($('attempt-form').elements.shooterId, people, $('attempt-form').elements.shooterId.value);
  $('demo-banner').hidden = !data.demo;
  $('stat-shooters').textContent = data.shooters.length;
  $('stat-runs').textContent = data.attempts.length;
  const runs = data.attempts.filter(a=>a.exercise === $('exercise').value && a.complete);
  $('stat-hf').textContent = runs.length ? fmt(Math.max(...runs.map(a=>score(a).hf))) : '—';
  $('stat-time').textContent = runs.length ? fmt(Math.min(...runs.map(a=>a.time)))+' с' : '—';
  $('roster-list').replaceChildren();
  data.shooters.forEach(s=>{
    const item = node('div',null,{class:'roster-item'}), info=node('div'), edit=node('button','↗',{'aria-label':'Редактировать: '+s.name});
    info.append(node('strong',s.name),node('small',s.division || 'Дивизион не указан'));
    item.append(node('span',s.name.split(/\s+/).slice(0,2).map(n=>n[0]).join(''),{class:'avatar'}),info,edit);
    edit.onclick=()=>openShooter(s); $('roster-list').append(item);
  });
  if (!data.shooters.length) $('roster-list').append(node('p','Добавьте первого стрелка, чтобы начать тренировку.',{class:'empty'}));
  const best = new Map(); runs.forEach(a=>{if (!best.has(a.shooterId) || score(a).hf > score(best.get(a.shooterId)).hf) best.set(a.shooterId,a);});
  table($('leaderboard'),['#','Стрелок','Время','HF'],[...best.values()].sort((a,b)=>score(b).hf-score(a).hf).map((a,i)=>[i+1,name(a.shooterId),fmt(a.time),fmt(score(a).hf)]));
  table($('history-table'),['Дата','Стрелок','Упражнение','Фактор','Статус','Время','A / C / D','M / NS / Проц.','Очки','HF'],[...data.attempts].sort((a,b)=>b.createdAt-a.createdAt).map(a=>[new Date(a.createdAt).toLocaleString('ru-RU'),name(a.shooterId),a.exercise,a.power,a.complete?'Завершена':'Не завершена',fmt(a.time),[a.a,a.c,a.d].join(' / '),[a.m,a.ns,a.procedures].join(' / '),score(a).points,score(a).hf === null?'—':fmt(score(a).hf)]));
  renderPicks(); renderChart(); renderDuel();
}
function renderPicks() {
  $('compare-picks').replaceChildren();
  data.shooters.forEach(s=>{
    const i=selected.indexOf(s.id), label=node('label',null,{class:'pick'}),input=node('input',null,{type:'checkbox',value:s.id});
    input.checked=selected.includes(s.id); input.disabled=!input.checked && selected.length>=MAX_COMPARE;
    const ns='http://www.w3.org/2000/svg',sample=document.createElementNS(ns,'svg'),line=document.createElementNS(ns,'line');sample.setAttribute('viewBox','0 0 24 8');sample.setAttribute('width','24');sample.setAttribute('height','8');sample.setAttribute('aria-hidden','true');for(const[k,v]of Object.entries({x1:0,x2:24,y1:4,y2:4,stroke:colors[i]||'#aaa','stroke-width':2,'stroke-dasharray':patterns[i]||''}))line.setAttribute(k,v);sample.append(line);
    label.append(input,sample,document.createTextNode(s.name)); $('compare-picks').append(label);
    input.onchange=()=>{selected=input.checked?[...selected,s.id]:selected.filter(id=>id!==s.id);renderPicks();renderChart();};
  });
  $('selected-count').textContent=selected.length+' / 10 стрелков';
}
function renderChart() {
  const runs=latest(data,$('exercise').value,selected), plotted=runs.filter(a=>a.shots.length);
  $('chart').replaceChildren();
  const values = a=>mode==='total'?a.shots:a.shots.map((v,i)=>v-(a.shots[i-1]||0));
  if (!plotted.length) $('chart').append(node('p','Выберите стрелков с временами выстрелов в этом упражнении.',{class:'empty'}));
  else {
    const ns='http://www.w3.org/2000/svg', svg=(tag,attrs,text)=>{const e=document.createElementNS(ns,tag);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,v);if(text)e.textContent=text;return e;};
    const chart=svg('svg',{viewBox:'0 0 1000 310',role:'img','aria-labelledby':'chart-title chart-desc',class:'chart-svg'});
    chart.append(svg('title',{id:'chart-title'},mode==='total'?'Накопленное время выстрелов':'Сплиты выстрелов'),svg('desc',{id:'chart-desc'},'Ось X: номер выстрела. Ось Y: секунды. Линии различаются цветом и штрихом. Имена и значения доступны в таблице под графиком.'));
    const maxX=Math.max(...plotted.map(a=>a.shots.length)),maxY=Math.max(.1,...plotted.flatMap(values))*1.13;
    const x=i=>60+(maxX===1?440:i/(maxX-1)*910),y=v=>260-v/maxY*220;
    for(let i=0;i<=4;i++){const v=maxY*i/4;chart.append(svg('line',{x1:60,y1:y(v),x2:970,y2:y(v),stroke:'#e8eaec','stroke-dasharray':'3 4'}),svg('text',{x:45,y:y(v)+4,'text-anchor':'end',fill:'#73777e','font-size':11},fmt(v)));}
    const tickStep=Math.max(1,Math.ceil(maxX/20));
    for(let i=0;i<maxX;i++)if(i%tickStep===0||i===maxX-1)chart.append(svg('text',{x:x(i),y:282,'text-anchor':'middle',fill:'#73777e','font-size':11},String(i+1)));
    chart.append(svg('text',{x:60,y:21,fill:'#73777e','font-size':10},'СЕКУНДЫ'),svg('text',{x:970,y:306,'text-anchor':'end',fill:'#73777e','font-size':10},'НОМЕР ВЫСТРЕЛА'));
    plotted.forEach(a=>{
      const i=selected.indexOf(a.shooterId), points=values(a).map((v,j)=>x(j)+','+y(v)).join(' ');
      chart.append(svg('polyline',{points,fill:'none',stroke:colors[i],'stroke-width':2.5,'stroke-dasharray':patterns[i],'stroke-linejoin':'round'}));
      values(a).forEach((v,j)=>{const dot=svg('circle',{cx:x(j),cy:y(v),r:3,fill:'white',stroke:colors[i],'stroke-width':1.7});dot.append(svg('title',{},name(a.shooterId)+' · выстрел '+(j+1)+' · '+fmt(v)+' с'));chart.append(dot);});
    }); $('chart').append(chart);
  }
  $('chart-note').textContent='Первый сплит = время от сигнала до первого выстрела. '+(runs.some(a=>!a.complete)?'На графике есть незавершённые попытки. ':'')+(runs.length<selected.length?'У части выбранных стрелков нет попытки в упражнении. ':'')+(runs.some(a=>!a.shots.length)?'Попытки без времён выстрелов не отображаются.':'');
  table($('chart-table'),['Стрелок','Статус','Выстрел','Время от сигнала, с','Сплит, с'],runs.flatMap(a=>a.shots.map((v,i)=>[name(a.shooterId),a.complete?'Завершена':'Не завершена',i+1,fmt(v),fmt(v-(a.shots[i-1]||0))])));
}
function renderDuel() {
  const ids=[$('duel-a').value,$('duel-b').value],runs=ids.map(id=>latest(data,$('exercise').value,[id])[0]),result=duel(...runs);
  $('duel-result').textContent=ids.includes(result)?'Лидер по HF: '+name(result):result;
  if(runs.every(Boolean)) $('duel-result').append(node('p',runs.map(a=>name(a.shooterId)+': '+(score(a).hf===null?'не завершена':fmt(score(a).hf)+' HF')+' · '+fmt(a.time)+' с').join(' / ')));
}
function confirmAction(title,copy,action) {
  $('confirm-title').textContent=title;$('confirm-copy').textContent=copy;
  const d=$('confirm-dialog');d.returnValue='';d.onclose=()=>{if(d.returnValue==='yes')action();};d.showModal();
}
function openShooter(s) {editing=s?.id??null;$('shooter-title').textContent=s?'Редактировать стрелка':'Новый стрелок';$('shooter-form').elements.name.value=s?.name??'';$('shooter-form').elements.division.value=s?.division??'';$('shooter-dialog').showModal();}
$('add-shooter').onclick=()=>openShooter();
$('shooter-form').onsubmit=e=>{e.preventDefault();if(!editing && data.shooters.length>=1000){notice("Достигнут лимит 1 000 стрелков.");return;}const f=e.currentTarget,s={id:editing||crypto.randomUUID(),name:f.elements.name.value.trim(),division:f.elements.division.value.trim()};if(!s.name){f.elements.name.setCustomValidity('Введите имя');f.elements.name.reportValidity();return;}f.elements.name.setCustomValidity('');if(editing)data.shooters=data.shooters.map(v=>v.id===editing?s:v);else{data.shooters.push(s);if(selected.length<10)selected.push(s.id);}persist();render();$('shooter-dialog').close();};
$('shooter-form').elements.name.oninput=e=>e.target.setCustomValidity('');
function readAttempt() {
  const f=$('attempt-form').elements,a={id:crypto.randomUUID(),shooterId:f.shooterId.value,exercise:f.exercise.value.trim(),power:f.power.value,time:Number(f.time.value),complete:f.complete.checked,createdAt:Date.now(),shots:shots(f.shots.value)};
  for(const k of ['a','c','d','m','ns','procedures'])a[k]=Number(f[k].value);
  return a;
}
$('new-attempt').onclick=()=>{if(!data.shooters.length){notice('Сначала добавьте стрелка.');openShooter();return;}$('attempt-form').reset();$('attempt-form').elements.exercise.value=$('exercise').value||'El Presidente';$('attempt-error').textContent='';$('score-preview').textContent='Очки: 0 · HF: —';$('attempt-dialog').showModal();};
$('attempt-form').oninput=()=>{try{const a=readAttempt(),s=score(a);$('score-preview').textContent='Очки: '+s.points+' · HF: '+(s.hf===null||!Number.isFinite(s.hf)?'—':fmt(s.hf));}catch{$('score-preview').textContent='Проверьте времена выстрелов';}};
$('attempt-form').onsubmit=e=>{e.preventDefault();try{const a=readAttempt();validate({...data,attempts:[...data.attempts,a]});data.attempts.push(a);persist();render();$('exercise').value=a.exercise;render();$('attempt-dialog').close();}catch(err){$('attempt-error').textContent=err.message;}};
document.querySelectorAll('[data-close]').forEach(b=>b.onclick=()=>b.closest('dialog').close());
$('exercise').onchange=render;$('duel-a').onchange=renderDuel;$('duel-b').onchange=renderDuel;
for(const m of ['splits','total'])$('mode-'+m).onclick=()=>{mode=m;for(const k of ['splits','total'])$('mode-'+k).setAttribute('aria-pressed',String(k===m));renderChart();};
function download(content,filename,type) {const url=URL.createObjectURL(new Blob([content],{type})),a=node('a',null,{href:url,download:filename});a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
$('export-json').onclick=()=>download(JSON.stringify(data,null,2),'pace-training.json','application/json');
$('export-csv').onclick=()=>download(csv(data),'pace-attempts.csv','text/csv;charset=utf-8');
$('import-json').onchange=async e=>{const file=e.target.files[0];if(!file)return;try{if(file.size>5*1024*1024)throw Error('Размер JSON не должен превышать 5 МБ.');const incoming=validate(JSON.parse(await file.text()));confirmAction('Заменить все данные?','В файле: '+incoming.shooters.length+' стрелков и '+incoming.attempts.length+' попыток. Текущие данные будут заменены. Сначала экспортируйте JSON, если нужна копия.',()=>{data=incoming;selected=data.shooters.slice(0,10).map(s=>s.id);storageBlocked=false;notice('Данные импортированы.');persist();render();});}catch(err){notice('Импорт отклонён: '+err.message);}finally{e.target.value='';}};
function erase(){confirmAction('Очистить все данные?','Будут удалены все стрелки и попытки в этом браузере. Перед удалением можно сохранить JSON.',()=>{data={version:1,demo:false,shooters:[],attempts:[]};selected=[];storageBlocked=false;notice('Данные очищены.');persist();render();});}
$('clear-demo').onclick=erase;$('erase').onclick=erase;
render();
