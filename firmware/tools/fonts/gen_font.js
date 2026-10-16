// 设备上的像素中文字体是怎么造出来的（字体本体 7MB 不进仓库，只进生成产物）。
//
// 源字体：缝合像素 Fusion Pixel（OFL-1.1，字体自带许可证见 main/board/fonts/*-OFL.txt）
//   https://github.com/TakWolf/fusion-pixel-font/releases  按设计档分 8px / 10px / 12px 三套
//
// 为什么只有"设计档 × 整数倍"能选：这些字体 unitsPerEm = 设计像素 × 100，栅格化到
// 整数倍尺寸时每个设计像素正好落成一个 N×N 实心块，1bpp 下没有阈值损失；非整数倍
// （比如 12px 设计出 20px）会变成"有的像素 2 格、有的 3 格"，等于回到矢量字糊掉那条路。
// 所以可选档位只有 8/16/24（12px 设计）、10/20（10px 设计）、8/16（8px 设计）。
//
// 现在装的是 **24px = 12px 设计档 × 2**。2026-10-14 先在 24 和 20 之间选了 20（"太大了"），
// 当天下午把状态带里"模式菜单"的"模"对着字库解出来看，才发现 20px 那档这个字本来就是糊的：
// 14 画压进 18 像素宽，笔画之间的缝只剩 2 格，墨量 59%（同屏的"式"只有 41%）→ 换回 24 再看。
// 20px = 10px 设计档 ×2（已对 500 个字形 36,052 个格子逐格验过 2×2 全一致）。这一档的 .c
// 没进仓库（2.4MB，已经否掉），要换回去按上面步骤生成，再动 CMakeLists 那一行加 card_ui.cc
// 里的字体名。
//
// 别再找 16px 的像素中文：方舟像素 Ark Pixel 的 16px 档在**每一个**历史 release 里都只有
// 97 个汉字（2026.09.01 和 2026.09.25 两个包都解过 cmap，不是只在最新版被废弃）。
//
// 字表覆盖的账（对着 puhui-symbols.txt 那 6,639 个码位核过）：
//   12px 设计档 zh_hans：缺 10 个汉字（嬷栾毂瘙芪蚝骶鳌鸾鹭）
//   10px 设计档 zh_hans：缺 31 个汉字（嗪娲峥嵘恺枭栀栾桡烨玮玺痫瘘绾羟胫蚝讷谙谟赈轶酰钰霁靓髋髙鸾龈）
//   两家都没有 IPA（U+0250-02FF 零字形）→ 音标和音节仍然走 font_ipa_14_1。
//
// 步骤（在本目录）：
//   0. npm i lv_font_conv
//   1. 把 zh_hans 的 ttf 放这儿
//   2. node extract-cp.js ../../main/board/fonts/font_puhui_14_1.c   # 生成 puhui-symbols.txt
//   3. node gen_font.js fusion-pixel-12px-proportional-zh_hans.ttf \
//        ../../main/board/fonts/font_pixel_24_1.c font_pixel_24_1 24
//
// 字表取的是 font_puhui_14_1 现有覆盖的码位，逐字对齐，换字体不会让任何一个
// 原来显示得出的字变成缺字（除了上面列的那几十个字）。
//
// 验收项（2026-10-14 实拍咬过一次）：生成完先确认 U+0020 在 cmap 里 —— 空格缺了
// LVGL 会画一个空心占位框，整屏的空格全变方框。


const {spawnSync}=require('child_process');const fs=require('fs');
// lv_font_conv 从本地依赖解析；装别处就设 CONV 指过去。
const CONV=process.env.CONV||require.resolve('lv_font_conv/lv_font_conv.js');
const src=process.argv[2], out=process.argv[3], name=process.argv[4], size=+(process.argv[5]||24);
const symbols=fs.readFileSync('puhui-symbols.txt','utf8');
const args=[CONV,'--font',src,'--symbols',symbols,'--size',String(size),'--bpp','1','--format','lvgl',
  '--lv-include','lvgl.h','--lv-font-name',name,'--no-compress','--no-prefilter','--force-fast-kern-format','-o',out];
const r=spawnSync(process.execPath,args,{maxBuffer:1<<28});
if(r.status!==0){console.log('FAIL',r.status);console.log(r.stderr.toString().slice(0,800));process.exit(1)}
const t=fs.readFileSync(out,'utf8');
const bm=[...t.split('glyph_bitmap[] = {')[1].split('\n};')[0].matchAll(/0x([0-9a-fA-F]+)/g)].map(m=>parseInt(m[1],16));
const dsc=(t.split('glyph_dsc[] =')[1]||'').split(/^};/m)[0];
const n=(dsc.match(/bitmap_index/g)||[]).length;
console.log(`${out}: 源码 ${(fs.statSync(out).size/1048576).toFixed(2)} MB | 位图字节 ${bm.length} (${(bm.length/1024).toFixed(0)} KB) | 字形 ${n-1} | 字体名 ${name}`);
