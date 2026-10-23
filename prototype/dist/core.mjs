export const MAX_COMPARE = 10;
export function score(a) {
  const points = Math.max(0, a.a * 5 + a.c * (a.power === 'Major' ? 4 : 3) + a.d * (a.power === 'Major' ? 2 : 1) - 10 * (a.m + a.ns + a.procedures));
  return {points, hf: a.complete ? points / a.time : null};
}
export function shots(text) {
  if (!text.trim()) return [];
  const values = text.trim().split(/[;\s,]+/).map(Number);
  if (values.some((n, i) => !Number.isFinite(n) || n <= 0 || (i && n <= values[i - 1]))) throw Error('Времена выстрелов должны быть положительными и строго возрастать. Используйте точку для дробной части.');
  return values;
}
export function validate(data) {
  if (!data || data.version !== 1 || typeof data.demo !== 'boolean' || !Array.isArray(data.shooters) || !Array.isArray(data.attempts) || data.shooters.length > 1000 || data.attempts.length > 10000) throw Error('Неверный формат файла или превышен лимит: 1 000 стрелков / 10 000 попыток.');
  const ids = new Set(), attemptIds = new Set();
  const validText = (v, max = 100) => typeof v === 'string' && v.trim().length > 0 && v.length <= max;
  for (const s of data.shooters) {
    if (!validText(s.id) || ids.has(s.id) || !validText(s.name) || typeof s.division !== 'string' || s.division.length > 80) throw Error('Некорректный стрелок или повтор ID.');
    ids.add(s.id);
  }
  for (const a of data.attempts) {
    if (!validText(a.id) || attemptIds.has(a.id) || !ids.has(a.shooterId) || !validText(a.exercise) || !['Minor','Major'].includes(a.power) || typeof a.complete !== 'boolean' || !Number.isFinite(a.time) || a.time <= 0 || a.time > 86400 || !Number.isFinite(a.createdAt) || a.createdAt < 0 || a.createdAt > 8640000000000000) throw Error('Некорректная попытка.');
    attemptIds.add(a.id);
    for (const key of ['a','c','d','m','ns','procedures']) if (!Number.isSafeInteger(a[key]) || a[key] < 0 || a[key] > 10000) throw Error('Попадания и штрафы должны быть целыми числами от 0 до 10 000.');
    if (!Array.isArray(a.shots) || a.shots.length > 1000 || a.shots.some((v,i) => !Number.isFinite(v) || v <= 0 || v > a.time || (i > 0 && v <= a.shots[i-1]))) throw Error('Неверные времена выстрелов: последнее не должно превышать общее время.');
  }
  return data;
}
export function latest(data, exercise, selected) {
  if (selected.length > MAX_COMPARE) throw Error('Можно сравнить не больше 10 стрелков.');
  return selected.map(id => data.attempts.filter(a => a.shooterId === id && a.exercise === exercise).sort((a,b) => b.createdAt - a.createdAt)[0]).filter(Boolean);
}
export function duel(a,b) {
  if (!a || !b) return 'Для дуэли нужны две попытки в выбранном упражнении.';
  if (a.shooterId === b.shooterId) return 'Выберите двух разных стрелков.';
  if (!a.complete || !b.complete) return 'Результат не определён: есть незавершённая попытка.';
  const diff = score(a).hf - score(b).hf;
  return Math.abs(diff) < 1e-9 ? 'Ничья' : diff > 0 ? a.shooterId : b.shooterId;
}
export function csv(data) {
  const cell = value => '"' + String(value).replace(/^[\s]*[=+@-]/, "'$&").replaceAll('"', '""') + '"';
  const rows = [['Стрелок','Упражнение','Дата ISO','Статус','Фактор','Время, с','A','C','D','M','NS','Процедуры','Очки','Hit factor','Времена выстрелов, с']];
  for (const a of data.attempts) rows.push([data.shooters.find(s=>s.id === a.shooterId)?.name ?? '',a.exercise,new Date(a.createdAt).toISOString(),a.complete?'Завершена':'Не завершена',a.power,a.time,a.a,a.c,a.d,a.m,a.ns,a.procedures,score(a).points,score(a).hf ?? '',a.shots.join(' ')]);
  return '\uFEFF' + rows.map(row=>row.map(cell).join(',')).join('\r\n');
}
export function demo() {
  const names = ['Алексей Волков','Мария Соколова','Дмитрий Орлов','Анна Белова','Илья Морозов','Елена Зайцева','Павел Лебедев','Ольга Новикова','Сергей Козлов','Ирина Петрова'];
  const shooters = names.map((name,i)=>({id:'demo-'+i,name,division:i%2?'Production':'Standard'}));
  return {version:1,demo:true,shooters,attempts:shooters.map((s,i)=>({id:'run-'+i,shooterId:s.id,exercise:'El Presidente',power:'Minor',time: +(7.24+i*.31).toFixed(2),a:10-i%3,c:2+i%3,d:0,m:0,ns:0,procedures:0,complete:true,createdAt:Date.UTC(2026,9,18,8,i),shots:Array.from({length:12},(_,j)=>+(1.15+j*(.49+i*.024)).toFixed(2))}))};
}
