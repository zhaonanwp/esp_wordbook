const fs=require('fs');const src=fs.readFileSync(process.argv[2],'utf8');
const arrs={};
for(const m of src.matchAll(/static const (?:uint8_t|uint16_t) (\w+)\[\] = \{([\s\S]*?)\n\};/gm)){
  arrs[m[1]]=[...m[2].matchAll(/0x([0-9a-fA-F]+)|(\d+)/g)].map(x=>parseInt(x[1]!==undefined?x[1]:x[2], x[1]!==undefined?16:10));}
const cmapRaw=src.split('cmaps[] =')[1].split(/^};/m)[0];
const cps=new Set();let n=0;
for(const e of cmapRaw.matchAll(/\.range_start = (\d+), \.range_length = (\d+), \.glyph_id_start = (\d+),\s*\.unicode_list = (\w+|NULL), \.glyph_id_ofs_list = (\w+|NULL), \.list_length = (\d+), \.type = (\w+)/g)){
  n++;const start=+e[1], len=+e[2], ul=e[4], ofs=e[5];
  if(ul!=='NULL'){for(const v of (arrs[ul]||[]))cps.add(start+v)}
  else if(ofs!=='NULL'){const a=arrs[ofs]||[];for(let i=0;i<len;i++)if(a[i]!==0)cps.add(start+i)}
  else {for(let i=0;i<len;i++)cps.add(start+i)}
}
const a=[...cps].sort((x,y)=>x-y);
console.log('entries='+n,'codepoints='+a.length);
// 控制字符不进字库（\n \r 在 LVGL 里是换行不是字形），但 0x20 必须留：
// 上一版把空格也滤掉了，结果全设备的空格都画成空心盒（LVGL 查不到 0x20 会退回 .notdef）。
fs.writeFileSync('puhui-symbols.txt',a.filter(c=>c>=0x20).map(c=>String.fromCodePoint(c)).join(''));
const cjk=a.filter(c=>c>=0x4e00&&c<=0x9fff);
console.log('CJK='+cjk.length,'min='+cjk[0].toString(16),'max='+cjk[cjk.length-1].toString(16));
