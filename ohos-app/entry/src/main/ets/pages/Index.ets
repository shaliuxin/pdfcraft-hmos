// PdfCraft for HarmonyOS —— PDF 阅读器主界面（还原原版观感 + 核心阅读功能）。
//
// 数据流：选文件 → 读整份字节 → pdfc.open 得句柄 →
//   显示：pdfc.renderPage 拿某页 RGBA8888 → createPixelMap → Image
//   属性：pdfc.metadata → JSON → DocMeta
//   书签：pdfc.outline → JSON → OutlineItem[]
//   搜索：pdfc.search → JSON → 每页命中矩形 → 跳页 + 高亮
// 纯 Rust 核心在后台渲染，ArkTS 负责取文件、显示、翻页、缩放、搜索、书签、属性。

import pdfc from 'libentry.so';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { i18n } from '@kit.LocalizationKit';

const DOMAIN: number = 0x3200;
const TAG: string = 'Index';
const PREF_NAME: string = 'pdfcraft-prefs';
const RECENT_MAX: number = 8;
// 应用版本号（跟随上游 pdfcraft workspace 版本，与 AppScope/app.json5 的 versionName 保持一致）
const APP_VERSION: string = '0.20.0';
const APP_NAME: string = 'PdfCraft';
const APP_BUNDLE: string = 'cn.shaliuxin.pdfcraft';

// 渲染固定倍率：每页只按此分辨率渲染一次（足够清晰），之后缩放只改显示尺寸。
const RENDER_SCALE: number = 3.0;
const ZOOM_MIN: number = 0.7;
const ZOOM_MAX: number = 3.0;

// ---- 主题（对齐 pdfcraft 原版 `crates/ui-egui/src/theme.rs` 的 hex 常量）----
interface ThemeColors {
  bg: string;         // 画布外区域（原版 pasteboard）
  bar: string;        // 工具栏/面板底（原版 chrome）
  titlebar: string;   // 顶栏/tab 条（原版 titlebar）
  text: string;       // 主文字
  sub: string;        // 次要文字（原版 text_muted）
  faint: string;      // 弱化文字（原版 text_faint）
  accent: string;     // 强调色
  accent_soft: string;// 强调浅底（原版 accent_soft，选中标签底）
  divider: string;    // 分隔线
  border: string;     // 控件边框（原版 border）
  panel: string;      // 面板（原版 panel）
  card: string;       // 卡片（原版 card）
  chip: string;       // 悬停/按下底（原版 hover）
  icon: string;       // 图标（原版 icon）
}

function lightTheme(): ThemeColors {
  // 来源：crates/ui-egui/src/theme.rs L74-97（浅色 Tokens）
  return {
    bg: '#F1F1F3', bar: '#FFFFFF', titlebar: '#E9E9EB', text: '#222226', sub: '#5E5E66',
    faint: '#6B6B73', accent: '#1B63E0', accent_soft: '#E3ECFD', divider: '#E8E8EB',
    border: '#DADADE', panel: '#FFFFFF', card: '#FFFFFF', chip: '#F0F0F3', icon: '#44444B'
  };
}

function darkTheme(): ThemeColors {
  // 来源：crates/ui-egui/src/theme.rs L98-121（深色 Tokens）
  return {
    bg: '#19191C', bar: '#26262A', titlebar: '#1B1B1E', text: '#ECECEF', sub: '#AEAEB6',
    faint: '#97979E', accent: '#4B8BF5', accent_soft: '#243657', divider: '#333339',
    border: '#3C3C43', panel: '#26262A', card: '#2E2E33', chip: '#34343A', icon: '#D4D4DA'
  };
}

// ---- 数据结构（ArkTS 不允许把对象字面量当类型，显式声明 interface）--------
interface FontInfo { name: string; kind: string; embedded: boolean }
interface DocMeta {
  title: string; author: string; subject: string; keywords: string;
  creator: string; producer: string; pdfVersion: string;
  fileSize: number; pages: number; encrypted: boolean;
  fonts: FontInfo[]; pageSize: number[][];
}
interface OutlineItem { title: string; page: number; }
interface OutlineResult { more: boolean; items: OutlineItem[]; }
interface SearchHitPage { page: number; count: number; rects: number[][]; }
interface SearchResults { total: number; pages: SearchHitPage[]; }
interface Match { page: number; rect: number[]; } // rect = [x0,y0,x1,y1]（PDF 点，y 向下）

// 欢迎页：推荐工具卡（对齐 home.rs L12 的 RECOMMENDED 5 组 + catalog.rs 的 label/icon/hue）
interface ToolCardDef {
  id: string;
  labelZh: string;
  labelEn: string;
  hue: string;
  descZh: string;
  descEn: string;
  ready: boolean;
}
const RECOMMENDED_TOOLS: ToolCardDef[] = [
  { id: 'organize', labelZh: '组织页面', labelEn: 'Organize pages', hue: '#2D9D5B', descZh: '旋转 · 删除 · 插入', descEn: 'Rotate · Delete · Insert', ready: true },
  { id: 'comment',  labelZh: '添加批注', labelEn: 'Add comments', hue: '#E88A1A', descZh: '高亮 · 笔记 · 回复', descEn: 'Highlight · Note · Reply', ready: true },
  { id: 'form',     labelZh: '准备表单', labelEn: 'Prepare a form', hue: '#8E4EE6', descZh: '文本 · 复选框 · 签名', descEn: 'Text · Checkbox · Signature', ready: true },
  { id: 'edit',     labelZh: '编辑 PDF', labelEn: 'Edit a PDF', hue: '#D63B8F', descZh: '添加文本 · 图片 · 链接', descEn: 'Add text · Image · Link', ready: true },
  { id: 'protect',  labelZh: '保护 PDF', labelEn: 'Protect a PDF', hue: '#3A6FE8', descZh: '密码 · 权限', descEn: 'Password · Permissions', ready: true },
];

// 最近文件（Preferences 持久化，最多 RECENT_MAX 条）
interface RecentFile {
  uri: string;
  name: string;
  size: number;
  pages: number;
  openedAt: number;
}

// renderPage 的返回结果（ArkTS 需显式类型，不用对象字面量当类型）。
interface RenderedPage {
  width: number;
  height: number;
  rgba: ArrayBuffer;
}

// ---- 编辑会话（Rust 编辑命令的返回结构）------------------------------------
interface EditStateInfo {
  pages: number;
  dirty: boolean;
  canUndo: boolean;
  canRedo: boolean;
  encrypted: boolean;
  title: string;
  author: string;
  rotations: number[];
}
interface EditReply {
  ok: boolean;
  error: string;
  state: EditStateInfo;
  annotations?: EditAnnItem[];
  fields?: EditFieldItem[];
  index?: number;
  fieldName?: string;
  removed?: number;
}
interface EditAnnItem { kind: string; text: string; index: number; }
interface EditFieldItem { name: string; kind: string; }
interface EditAction { id: string; labelZh: string; labelEn: string; }
interface EditGroup { id: string; labelZh: string; labelEn: string; hue: string; actions: EditAction[]; }

// 五类编辑工具，逐条对应 crates/ohos/src/edit.rs 的 op。
const EDIT_GROUPS: EditGroup[] = [
  { id: 'organize', labelZh: '组织页面', labelEn: 'Organize pages', hue: '#2D9D5B', actions: [
    { id: 'rot90', labelZh: '右转 90°', labelEn: 'Rotate +90°' },
    { id: 'rot270', labelZh: '左转 90°', labelEn: 'Rotate −90°' },
    { id: 'insertBefore', labelZh: '当前页前插空白页', labelEn: 'Insert blank before' },
    { id: 'insertAfter', labelZh: '当前页后插空白页', labelEn: 'Insert blank after' },
    { id: 'duplicate', labelZh: '复制所选页', labelEn: 'Duplicate pages' },
    { id: 'reverse', labelZh: '反转所选页', labelEn: 'Reverse pages' },
    { id: 'moveTo', labelZh: '移动所选页到', labelEn: 'Move pages to' },
    { id: 'deletePages', labelZh: '删除所选页', labelEn: 'Delete pages' },
    { id: 'extract', labelZh: '抽取所选页', labelEn: 'Extract pages' },
    { id: 'setTitle', labelZh: '设置标题', labelEn: 'Set title' },
    { id: 'setAuthor', labelZh: '设置作者', labelEn: 'Set author' },
    { id: 'addBookmark', labelZh: '添加书签', labelEn: 'Add bookmark' },
    { id: 'numberPages', labelZh: '设置页码样式', labelEn: 'Number pages' },
  ] },
  { id: 'comment', labelZh: '添加批注', labelEn: 'Add comments', hue: '#E88A1A', actions: [
    { id: 'addNote', labelZh: '添加便签', labelEn: 'Add sticky note' },
    { id: 'addHighlight', labelZh: '添加高亮', labelEn: 'Add highlight' },
    { id: 'addRect', labelZh: '添加矩形', labelEn: 'Add rectangle' },
    { id: 'addOval', labelZh: '添加椭圆', labelEn: 'Add oval' },
    { id: 'addLine', labelZh: '添加直线', labelEn: 'Add line' },
    { id: 'listAnnotations', labelZh: '列出本页批注', labelEn: 'List annotations' },
    { id: 'setAnnotationText', labelZh: '修改批注内容', labelEn: 'Edit comment text' },
    { id: 'replyAnnotation', labelZh: '回复批注', labelEn: 'Reply to comment' },
    { id: 'deleteAnnotation', labelZh: '删除批注', labelEn: 'Delete comment' },
  ] },
  { id: 'form', labelZh: '准备表单', labelEn: 'Prepare a form', hue: '#8E4EE6', actions: [
    { id: 'addFieldText', labelZh: '文本域', labelEn: 'Text field' },
    { id: 'addFieldMulti', labelZh: '多行文本域', labelEn: 'Multiline text' },
    { id: 'addFieldCheck', labelZh: '复选框', labelEn: 'Check box' },
    { id: 'addFieldDate', labelZh: '日期域', labelEn: 'Date field' },
    { id: 'addFieldCombo', labelZh: '下拉框', labelEn: 'Combo box' },
    { id: 'addFieldSignature', labelZh: '签名域', labelEn: 'Signature field' },
    { id: 'setFieldValue', labelZh: '填写字段', labelEn: 'Fill field' },
    { id: 'listFields', labelZh: '列出字段', labelEn: 'List fields' },
    { id: 'deleteField', labelZh: '删除字段', labelEn: 'Delete field' },
    { id: 'resetForm', labelZh: '重置表单', labelEn: 'Reset form' },
  ] },
  { id: 'edit', labelZh: '编辑 PDF', labelEn: 'Edit a PDF', hue: '#D63B8F', actions: [
    { id: 'addText', labelZh: '添加文本', labelEn: 'Add text' },
    { id: 'addWatermark', labelZh: '添加水印', labelEn: 'Add watermark' },
    { id: 'addHeaderFooter', labelZh: '添加页脚页码', labelEn: 'Add footer page no.' },
    { id: 'removeWatermark', labelZh: '移除水印', labelEn: 'Remove watermark' },
    { id: 'deleteContent', labelZh: '删除添加的内容', labelEn: 'Delete added content' },
  ] },
  { id: 'protect', labelZh: '保护 PDF', labelEn: 'Protect a PDF', hue: '#3A6FE8', actions: [
    { id: 'encryptAes256', labelZh: 'AES-256 加密', labelEn: 'Encrypt (AES-256)' },
    { id: 'encryptAes128', labelZh: 'AES-128 加密', labelEn: 'Encrypt (AES-128)' },
    { id: 'removeEncryption', labelZh: '移除密码保护', labelEn: 'Remove protection' },
  ] },
];

@Entry
@Component
struct Index {
  // ⚠ 句柄是 bigint（NAPI 指针），@State 不支持 bigint → 用普通字段。
  private handle: bigint | null = null;
  private innerScroller: Scroller = new Scroller();
  private outerScroller: Scroller = new Scroller();

  @State hasDoc: boolean = false;
  @State themeDark: boolean = true;
  @State continuous: boolean = false;
  @State docName: string = '';
  @State pageCount: number = 0;
  @State curPage: number = 0;
  @State uiZoom: number = 1.0;
  @State loading: boolean = false;
  @State errMsg: string = '';

  @State pixmap: image.PixelMap | null = null;
  // 连续视图：每页由独立子组件 ContPage 懒渲染并自缓存，避免一次性渲染所有页冻住 UI 线程。
  @State contIndices: number[] = [];
  // 每次编辑后自增，作为 ForEach key 的一部分强制 ContPage 重建并清掉旧的像素缓存，
  // 否则删除/插入的页在连续视图里不刷新（子组件 pm 一旦加载就永不重算）。
  @State contRev: number = 0;

  // ---- 桌面版布局（对齐原版 ui-egui：模式条 + 左右面板 + 状态栏）----
  @State mode: string = 'alltools';       // alltools | edit | convert | esign（对应原版 Mode 枚举）
  @State showActions: boolean = false;    // 左侧：是否展开当前工具的动作列表（窄栏 ↔ 宽面板）
  @State panelOpen: string = '';          // 右侧面板：'' | bookmarks | fields | pages | props | attachments
  @State imgW: number = 0;
  @State imgH: number = 0;
  @State viewportW: number = 0;
  @State viewportH: number = 0;
  @State meta: DocMeta | null = null;

  @State showSearch: boolean = false;
  @State searchInput: string = '';
  @State searchResults: SearchResults | null = null;
  @State matches: Match[] = [];
  @State curMatch: number = -1;

  // 界面语言（'zh' / 'en'），初始跟随系统，用户可手动切换
  @State lang: string = 'zh';

  // 设置/关于对话框：showSettings 控制显隐，settingsTab 切换 通用(general) / 关于(about)
  @State showSettings: boolean = false;
  @State settingsTab: string = 'general';

  // 欢迎页：最近文件（Preferences 持久化，打开文档时自动追加、去重，最多 RECENT_MAX 条）
  @State recentFiles: RecentFile[] = [];

  // 底部抽屉：同一组件只能绑一个 bindSheet（绑两个时后者覆盖前者），
  // 所以用 sheetKind 区分书签/属性，共用一个抽屉。
  // 编辑工具单独用全屏面板（见 editPanel），不放进 bindSheet —— 内容多时抽屉会
  // 把控件挤到屏幕下部、动作列表被截断。
  @State sheetOpen: boolean = false;
  @State sheetKind: string = ''; // 'outline' | 'props'
  @State outlineItems: OutlineItem[] = [];
  @State outlineMore: boolean = false;

  // ---- 编辑会话（bigint 句柄不能放进 @State）----
  private editHandle: bigint | null = null;
  private docBytes: ArrayBuffer | null = null; // 原始 PDF 字节，供 editOpen 用
  private docUri: string = '';
  @State editOpen: boolean = false;   // 全屏编辑面板
  @State editTab: string = 'organize';
  @State editStateInfo: EditStateInfo | null = null;
  @State editMsg: string = '';
  @State editPages: string = '';   // 逗号分隔的 1 基页码，如 "1,3-5"；空则用当前页
  @State editText: string = '';    // 批注内容 / 标题 / 水印文字 / 字段名
  @State editValue: string = '';   // 字段值 / 作者 / 前缀
  @State editNum: string = '12';   // 字号 / 索引 / 目标位置等数值
  @State editPassword: string = '';  // 新建加密：用户密码
  @State editPassword2: string = ''; // 新建加密：确认密码
  @State editOwnerPw: string = '';   // 新建加密：所有者密码（空则同用户密码）
  @State openPassword: string = '';  // 打开当前「已加密」文档用的密码
  private previewPassword: string = ''; // 加密后刷新预览用的密码
  private lastEditId: string = '';      // 防重复触发：上一次动作 id
  private lastEditAt: number = 0;       // 防重复触发：上一次动作时间戳

  // ---- 打开加密文件时的密码对话框 ----
  @State needPassword: boolean = false;
  @State passwordInput: string = '';
  @State passwordHint: string = '';
  private pendingBytes: ArrayBuffer | null = null;
  private pendingUri: string = '';
  private pendingName: string = '';
  private pendingSize: number = 0;

  private pinchBase: number = 1.0;
  private docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));

  aboutToAppear(): void {
    this.initLangFromSystem();
    this.loadRecent();
    const uri: string | undefined = AppStorage.get<string>('pendingPdfUri');
    if (uri) {
      AppStorage.delete('pendingPdfUri');
      this.loadPdf(uri);
    }
  }

  // 语言辅助：按当前 lang 返回对应文案
  private t(zh: string, en: string): string {
    return this.lang === 'zh' ? zh : en;
  }

  // 初始语言：读 Preferences 里用户手设的，没有就跟随系统（i18n.GetLanguage）
  private initLangFromSystem(): void {
    try {
      const ctx = getContext(this);
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      const saved: string = pref.getSync('lang', '') as string;
      if (saved === 'zh' || saved === 'en') {
        this.lang = saved;
        return;
      }
    } catch (e) { /* 忽略，走系统默认 */ }
    try {
      const sysLang: string = i18n.getSystemLanguage(); // 'zh' / 'en' / 'ja' / ...
      this.lang = sysLang && sysLang.startsWith('zh') ? 'zh' : 'en';
    } catch (e) {
      this.lang = 'zh';
    }
  }

  private toggleLang(): void {
    this.lang = this.lang === 'zh' ? 'en' : 'zh';
    try {
      const ctx = getContext(this);
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync('lang', this.lang);
      pref.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'toggleLang save failed: %{public}s', String(e));
    }
  }

  /** 打开设置对话框：tab='general'（通用）或 'about'（关于）。 */
  private openSettings(tab: string): void {
    this.settingsTab = tab;
    this.showSettings = true;
  }

  /** 关闭设置对话框。 */
  private closeSettings(): void {
    this.showSettings = false;
  }

  /** 切换主题（设置面板内的按钮调用，与顶栏图标同一逻辑）。 */
  private toggleTheme(): void {
    this.themeDark = !this.themeDark;
  }

  /** 设置面板里切换阅读视图（单页 / 连续）。与 toggleLayout 保持一致的切换逻辑。 */
  private setContinuous(on: boolean): void {
    if (this.continuous === on) {
      return;
    }
    if (on) {
      this.continuous = true;
      if (this.hasDoc) {
        this.setupContinuous();
      }
    } else {
      this.continuous = false;
    }
  }

  // ---- 最近文件（Preferences 持久化）----
  private loadRecent(): void {
    try {
      const ctx = getContext(this);
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      const s: string = pref.getSync('recent', '[]') as string;
      if (s === '' || s === '[]') {
        this.recentFiles = [];
        return;
      }
      const arr: RecentFile[] = JSON.parse(s) as RecentFile[];
      if (arr && Array.isArray(arr)) {
        this.recentFiles = arr;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loadRecent failed: %{public}s', String(e));
      this.recentFiles = [];
    }
  }

  private saveRecent(uri: string, name: string, size: number, pages: number): void {
    const rest: RecentFile[] = this.recentFiles.filter((r: RecentFile) => r.uri !== uri);
    rest.unshift({ uri: uri, name: name, size: size, pages: pages, openedAt: Date.now() });
    while (rest.length > RECENT_MAX) {
      rest.pop();
    }
    this.recentFiles = rest.slice();
    try {
      const ctx = getContext(this);
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync('recent', JSON.stringify(this.recentFiles));
      pref.flush();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'saveRecent failed: %{public}s', String(e));
    }
  }

  private openRecent(r: RecentFile): void {
    this.loadPdf(r.uri);
  }

  // 关闭当前文档、回到欢迎页
  private goHome(): void {
    if (this.handle !== null) {
      try { pdfc.close(this.handle); } catch (e) { }
    }
    if (this.editHandle !== null) {
      try { pdfc.editClose(this.editHandle); } catch (e) { }
    }
    this.handle = null;
    this.editHandle = null;
    this.docBytes = null;
    this.docUri = '';
    this.editStateInfo = null;
    this.editMsg = '';
    this.editOpen = false;
    this.needPassword = false;
    this.previewPassword = '';
    this.openPassword = '';
    this.editPassword = '';
    this.editPassword2 = '';
    this.editOwnerPw = '';
    this.hasDoc = false;
    this.pixmap = null;
    this.contIndices = [];
    this.meta = null;
    this.outlineItems = [];
    this.matches = [];
    this.searchInput = '';
    this.showSearch = false;
    this.sheetOpen = false;
    this.errMsg = '';
  }

  private c(): ThemeColors {
    return this.themeDark ? darkTheme() : lightTheme();
  }

  /** 打开书签 / 属性抽屉。编辑工具走独立的全屏面板，不与抽屉共用。 */
  private openSheet(kind: string): void {
    if (this.sheetOpen && this.sheetKind === kind) {
      this.sheetOpen = false;
    } else {
      this.sheetKind = kind;
      this.sheetOpen = true;
    }
    this.showSearch = false;
    this.editOpen = false;
  }

  // ---- 编辑会话 -----------------------------------------------------------
  // 说明：pdfcraft-engine（桌面版 Session）含 aws-lc-sys/boa/reqwest 等 C 与桌面依赖，
  // 无法为 OHOS 交叉编译；这里改为直接驱动纯 Rust 的 cos/organize/annot/forms/edit crate
  // （见 crates/ohos/src/edit.rs），所有 op 都在宿主机端到端测试里验证过。

  private esc(s: string): string {
    return JSON.stringify(s);
  }

  /** 把 "1,3-5" 这样的 1 基页码串解析成 0 基 JSON 数组；空则默认当前页。 */
  private pagesArg(): string {
    const raw: string = this.editPages.trim();
    if (raw === '') {
      return '[' + this.curPage + ']';
    }
    const out: number[] = [];
    const parts: string[] = raw.split(/[,，\s]+/);
    for (const part of parts) {
      if (part === '') { continue; }
      const seg: string[] = part.split('-');
      const a: number = Number(seg[0]);
      const b: number = seg.length > 1 ? Number(seg[1]) : a;
      if (!Number.isFinite(a)) { continue; }
      const hi: number = Number.isFinite(b) ? Math.max(a, b) : a;
      const lo2: number = Math.max(1, Math.floor(Math.min(a, hi)));
      const hi2: number = Math.min(this.pageCount, Math.floor(hi));
      for (let n: number = lo2; n <= hi2; n++) { out.push(n - 1); }
    }
    if (out.length === 0) { return '[' + this.curPage + ']'; }
    return JSON.stringify(out);
  }

  /** 当前页中部的一个默认矩形（PDF 点），供批注/表单/文本使用。 */
  private pageRectArg(): string {
    let w: number = 612;
    let h: number = 792;
    if (this.meta !== null && this.meta.pageSize.length > this.curPage) {
      const p: number[] = this.meta.pageSize[this.curPage];
      if (p[0] > 0) { w = p[0]; }
      if (p[1] > 0) { h = p[1]; }
    }
    const x0: number = Math.round(w * 0.12);
    const y0: number = Math.round(h * 0.18);
    const x1: number = Math.round(w * 0.75);
    const y1: number = Math.round(h * 0.28);
    return '[' + x0 + ',' + y0 + ',' + x1 + ',' + y1 + ']';
  }

  /** 高亮用的四边形：[左上, 右上, 左下, 右下]，与 pageRectArg 同一区域。 */
  private quadsArg(): string {
    let w: number = 612;
    let h: number = 792;
    if (this.meta !== null && this.meta.pageSize.length > this.curPage) {
      const p: number[] = this.meta.pageSize[this.curPage];
      if (p[0] > 0) { w = p[0]; }
      if (p[1] > 0) { h = p[1]; }
    }
    const x0: number = Math.round(w * 0.12);
    const y0: number = Math.round(h * 0.18);
    const x1: number = Math.round(w * 0.75);
    const y1: number = Math.round(h * 0.28);
    return '[[' + x0 + ',' + y1 + ',' + x1 + ',' + y1 + ',' + x0 + ',' + y0 + ',' + x1 + ',' + y0 + ']]';
  }

  private numArg(): number {
    const n: number = Number(this.editNum);
    return Number.isFinite(n) ? n : 12;
  }

  private currentActions(): EditAction[] {
    for (const g of EDIT_GROUPS) {
      if (g.id === this.editTab) { return g.actions; }
    }
    return [];
  }

  private currentGroupLabel(): string {
    for (const g of EDIT_GROUPS) {
      if (g.id === this.editTab) { return this.t(g.labelZh, g.labelEn); }
    }
    return '';
  }

  private editStatusLine(): string {
    const s: EditStateInfo | null = this.editStateInfo;
    if (s === null) { return this.t('未开始编辑', 'No edit session'); }
    return this.t('页数 ', 'Pages ') + s.pages + ' · ' +
      (s.encrypted ? this.t('已加密', 'Encrypted') : this.t('未加密', 'Not encrypted')) + ' · ' +
      (s.dirty ? this.t('有未保存修改', 'Unsaved changes') : this.t('无修改', 'No changes'));
  }

  /** 打开（或复用）编辑会话。已加密的文档用 openPassword 解锁。 */
  private ensureEditor(): boolean {
    if (this.editHandle !== null) { return true; }
    if (this.docBytes === null) {
      this.editMsg = this.t('请先打开一份 PDF', 'Open a PDF first');
      return false;
    }
    // 注意：这里绝不能用"新建加密密码"(editPassword) 去打开文档——那会把一个明文
    // 文件当成加密文件，导致编辑会话永远打不开。两者分开存放。
    let h: bigint | null = pdfc.editOpen(this.docBytes);
    if (h === null && this.openPassword !== '') {
      h = pdfc.editOpen(this.docBytes, this.openPassword);
    }
    if (h === null) {
      this.editMsg = this.t('无法开始编辑：文档可能已加密，请在「保护 PDF → 当前文档密码」里填入密码后重试',
        'Cannot start editing: the file may be encrypted. Enter its password under Protect a PDF.');
      return false;
    }
    this.editHandle = h;
    this.readEditState();
    return true;
  }

  private readEditState(): void {
    const h: bigint | null = this.editHandle;
    if (h === null) { return; }
    try {
      const s: string = pdfc.editState(h);
      if (s !== '') { this.editStateInfo = JSON.parse(s) as EditStateInfo; }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'editState failed: %{public}s', String(e));
    }
  }

  /** 把只读命令（列出批注/字段等）的结果转成可读提示，否则显示「已完成」。 */
  private extraToMessage(r: EditReply): string {
    if (r.annotations !== undefined) {
      if (r.annotations.length === 0) { return this.t('本页没有批注', 'No comments on this page'); }
      let s: string = this.t('本页批注：', 'Comments: ');
      for (const a of r.annotations) {
        s += '[' + a.index + '] ' + a.kind + (a.text === '' ? '' : ': ' + a.text) + '  ';
      }
      return s;
    }
    if (r.fields !== undefined) {
      if (r.fields.length === 0) { return this.t('文档没有表单字段', 'No form fields'); }
      let s: string = this.t('表单字段：', 'Fields: ');
      for (const f of r.fields) { s += f.name + ' (' + f.kind + ')  '; }
      return s;
    }
    if (r.fieldName !== undefined) {
      return this.t('已添加字段：', 'Field added: ') + r.fieldName;
    }
    if (r.removed !== undefined) {
      return this.t('已移除 ', 'Removed ') + r.removed + this.t(' 处', ' marks');
    }
    if (r.index !== undefined) {
      return this.t('已完成（索引 ', 'Done (index ') + r.index + ')';
    }
    return this.t('已完成', 'Done');
  }

  /** 执行一条编辑命令；成功后刷新预览、更新状态。gotoPage >= 0 时把视图移到该页（如新插入的空白页）。 */
  private execEdit(cmd: string, preview: boolean = true, gotoPage: number = -1): boolean {
    if (!this.ensureEditor()) { return false; }
    const h: bigint | null = this.editHandle;
    if (h === null) { return false; }
    let out: string = '';
    try {
      out = pdfc.editCommand(h, cmd);
    } catch (e) {
      this.editMsg = this.t('命令执行出错：', 'Command failed: ') + String(e);
      return false;
    }
    if (out === '') {
      this.editMsg = this.t('命令无返回（会话可能已失效）', 'No result (session may be invalid)');
      return false;
    }
    try {
      const r: EditReply = JSON.parse(out) as EditReply;
      if (r.ok) {
        if (r.state !== null && r.state !== undefined) { this.editStateInfo = r.state; }
        this.editMsg = this.extraToMessage(r);
        if (gotoPage >= 0) { this.curPage = gotoPage; }
        if (preview) { this.refreshPreview(gotoPage); }
        return true;
      } else {
        this.editMsg = this.t('失败：', 'Failed: ') + r.error;
      }
    } catch (e) {
      this.editMsg = this.t('无法解析命令结果：', 'Cannot parse result: ') + String(e);
    }
    return false;
  }

  /** 把编辑后的字节重新载入渲染句柄，让用户立刻看到修改结果。gotoPage >= 0 时尽量跳到该页。 */
  private refreshPreview(gotoPage: number = -1): void {
    const eh: bigint | null = this.editHandle;
    if (eh === null) { return; }
    const bytes: ArrayBuffer | null = pdfc.editSave(eh, false);
    if (bytes === null) { return; }
    // 先按明文打开；读不出页面（说明导出字节是加密的）再用已知密码重试。
    // 这样加密 / 解密 / 撤销加密之后都能立刻刷新预览。
    let h: bigint | null = pdfc.open(bytes);
    if (h !== null && pdfc.pageCount(h) <= 0 && this.previewPassword !== '') {
      pdfc.close(h);
      h = pdfc.open(bytes, this.previewPassword);
    }
    if (h === null || pdfc.pageCount(h) <= 0) { return; } // 密码不对：保留旧预览
    if (this.handle !== null) {
      try { pdfc.close(this.handle); } catch (e) { }
    }
    this.handle = h;
    this.pageCount = pdfc.pageCount(h);
    if (gotoPage >= 0 && gotoPage < this.pageCount) { this.curPage = gotoPage; }
    if (this.curPage >= this.pageCount) { this.curPage = this.pageCount - 1; }
    if (this.curPage < 0) { this.curPage = 0; }
    // 无论单页还是连续，都把当前页渲染到 this.pixmap：编辑面板的"实时预览"和单页视图都靠它。
    this.renderCurrent();
    if (this.continuous) {
      // 连续视图：重建页索引并自增 rev，强制所有 ContPage 用最新 handle 重建（清旧缓存），
      // 删除/插入的页才会真正反映出来；再尽量把视口滚到新插入的页。
      this.setupContinuous();
      this.contRev++;
      if (gotoPage >= 0) {
        const rowH: number = this.viewportW * this.contAspect() + 10;
        const y: number = Math.max(0, gotoPage * rowH - this.viewportH * 0.35);
        this.outerScroller.scrollTo({ xOffset: 0, yOffset: y });
      } else {
        this.resetScroll();
      }
    }
    this.loadMeta();
    this.loadOutline();
  }

  private editUndo(): void {
    if (!this.ensureEditor()) { return; }
    const h: bigint | null = this.editHandle;
    if (h === null) { return; }
    const r: EditReply = JSON.parse(pdfc.editUndo(h)) as EditReply;
    this.editStateInfo = r.state;
    this.editMsg = r.ok ? this.t('已撤销', 'Undone') : r.error;
    if (r.ok) {
      this.previewPassword = (r.state !== null && r.state !== undefined && r.state.encrypted)
        ? (this.previewPassword !== '' ? this.previewPassword : this.openPassword) : '';
      this.refreshPreview();
    }
  }

  private editRedo(): void {
    if (!this.ensureEditor()) { return; }
    const h: bigint | null = this.editHandle;
    if (h === null) { return; }
    const r: EditReply = JSON.parse(pdfc.editRedo(h)) as EditReply;
    this.editStateInfo = r.state;
    this.editMsg = r.ok ? this.t('已重做', 'Redone') : r.error;
    if (r.ok) {
      this.previewPassword = (r.state !== null && r.state !== undefined && r.state.encrypted)
        ? (this.previewPassword !== '' ? this.previewPassword : this.openPassword) : '';
      this.refreshPreview();
    }
  }

  /** 另存为：拿编辑后的 PDF 字节，通过系统文件选择器写到用户选的位置。 */
  private async saveEdited(): Promise<void> {
    if (!this.ensureEditor()) { return; }
    const h: bigint | null = this.editHandle;
    if (h === null) { return; }
    const bytes: ArrayBuffer | null = pdfc.editSave(h, true);
    if (bytes === null) {
      this.editMsg = this.t('导出失败', 'Export failed');
      return;
    }
    try {
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      const base: string = this.docName.replace(/\.pdf$/i, '');
      opts.newFileNames = [base + '-edited.pdf'];
      const uris: string[] = await this.docPicker.save(opts);
      if (!uris || uris.length === 0) {
        this.editMsg = this.t('已取消保存', 'Save cancelled');
        return;
      }
      const f: fs.File = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, bytes);
      fs.closeSync(f.fd);
      const locked: boolean = this.editStateInfo !== null && this.editStateInfo.encrypted;
      this.editMsg = this.t('已保存：', 'Saved: ') + uris[0] +
        (locked ? this.t('（已加密，打开时需要用户密码）', ' (encrypted; opening requires the user password)') : '');
      this.toast(this.t('PDF 已保存', 'PDF saved'));
    } catch (e) {
      this.editMsg = this.t('保存失败：', 'Save failed: ') + String(e);
    }
  }

  /** 从工具卡或顶栏进入某类编辑工具；没有文档时先选文件。 */
  private async openTool(id: string): Promise<void> {
    this.editTab = id;
    this.editMsg = '';
    if (!this.hasDoc) {
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      try {
        const uris: string[] = await this.docPicker.select(opts);
        if (uris && uris.length > 0) {
          await this.loadPdf(uris[0]);
          if (this.hasDoc) { this.showEditPanel(); }
        }
      } catch (e) {
        this.errMsg = this.t('选择文件出错：', 'Select file error: ') + String(e);
      }
      return;
    }
    this.showEditPanel();
  }

  private showEditPanel(): void {
    this.panelOpen = '';
    this.showActions = true;
    // 让模式条高亮与当前工具对应
    if (this.editTab === 'edit') {
      this.mode = 'edit';
    } else if (this.editTab === 'form') {
      this.mode = 'esign';
    } else if (this.editTab === 'protect') {
      this.mode = 'convert';
    } else {
      this.mode = 'alltools';
    }
  }

  // ---- 桌面版布局辅助（对齐原版 app.switch_mode / choose_right_panel）----

  /** 模式条切换：All tools / Edit / Convert / E-Sign。Edit/E-Sign 预选对应工具并展开动作面板。 */
  private switchMode(m: string): void {
    this.mode = m;
    this.panelOpen = '';
    if (!this.hasDoc) {
      return; // 没有文档时模式只影响高亮
    }
    if (m === 'edit') {
      this.editTab = 'edit';
      this.showActions = true;
    } else if (m === 'esign') {
      this.editTab = 'form'; // 表单/签名域
      this.showActions = true;
    } else if (m === 'convert') {
      this.editTab = 'protect'; // 保护/转换类
      this.showActions = true;
    } else {
      // alltools：回到全部工具
      this.showActions = true;
    }
  }

  /** 点左侧工具栏的某一类工具：选中它并展开其动作列表。 */
  private selectCategory(id: string): void {
    if (this.editTab === id && this.showActions) {
      this.showActions = false;
      return;
    }
    this.editTab = id;
    this.editMsg = '';
    this.showActions = true;
    // 让模式条高亮同步：除 alltools 外，edit/form 对应 E-Sign，protect 对应 Convert。
    if (id === 'edit') {
      this.mode = 'edit';
    } else if (id === 'form') {
      this.mode = 'esign';
    } else if (id === 'protect') {
      this.mode = 'convert';
    }
  }

  /** 点右侧面板切换按钮：开关对应面板（bookmarks/fields/pages/props/attachments）。 */
  private openPanel(kind: string): void {
    if (this.panelOpen === kind) {
      this.panelOpen = '';
      return;
    }
    this.panelOpen = kind;
    this.showActions = false;
    if (kind === 'pages') {
      // Pages 面板：切到连续缩略视图更直观
      this.continuous = true;
      this.setupContinuous();
    }
  }

  /** 状态栏消息（保存结果等），自动淡出。 */
  private status(msg: string): void {
    hilog.info(DOMAIN, TAG, 'status: %{public}s', msg);
    this.errMsg = msg;
    setTimeout(() => { if (this.errMsg === msg) { this.errMsg = ''; } }, 2600);
  }

  /** 当前显示页的 [宽, 高]（PDF 点）。插入空白页时与原版一致，跟随邻页尺寸。 */
  private curPageSize(): number[] {
    if (this.meta !== null && this.meta.pageSize.length > this.curPage) {
      const p: number[] = this.meta.pageSize[this.curPage];
      if (p[0] > 0 && p[1] > 0) { return [p[0], p[1]]; }
    }
    return [612, 792];
  }

  /** 把界面参数组装成一条编辑命令。 */
  private runEditAction(id: string): void {
    // 同一动作 600ms 内只执行一次，避免一次点击被重复触发（例如重复插入多页）。
    const now: number = Date.now();
    if (this.lastEditId === id && (now - this.lastEditAt) < 600) { return; }
    this.lastEditId = id;
    this.lastEditAt = now;
    try {
    const pg: number = this.curPage;
    const pages: string = this.pagesArg();
    const rect: string = this.pageRectArg();
    const quads: string = this.quadsArg();
    const text: string = this.esc(this.editText);
    const value: string = this.esc(this.editValue);
    const n: number = this.numArg();
    const name: string = this.esc(this.editText.trim() === '' ? '' : this.editText.trim());
    let cmd: string = '';
    let preview: boolean = true;
    let gotoPage: number = -1;

    switch (id) {
      // 组织页面
      case 'rot90': cmd = '{"op":"rotate","pages":' + pages + ',"degrees":90}'; break;
      case 'rot270': cmd = '{"op":"rotate","pages":' + pages + ',"degrees":-90}'; break;
      case 'insertBefore':
      case 'insertAfter': {
        // insert_blank_page 的 at 是「插入到该下标之前」的 0 基位置：
        // 当前页前 = curPage，当前页后 = curPage + 1。成功后跳到新页，避免新页堆在第一页后面看不见。
        const sz: number[] = this.curPageSize();
        const at: number = id === 'insertBefore' ? pg : pg + 1;
        cmd = '{"op":"insertBlank","at":' + at + ',"width":' + sz[0] + ',"height":' + sz[1] + '}';
        gotoPage = at;
        break;
      }
      case 'duplicate': cmd = '{"op":"duplicatePages","pages":' + pages + ',"at":null}'; break;
      case 'reverse': cmd = '{"op":"reversePages","pages":' + pages + '}'; break;
      case 'moveTo': cmd = '{"op":"movePages","pages":' + pages + ',"to":' + (n - 1) + '}'; break;
      case 'deletePages': cmd = '{"op":"deletePages","pages":' + pages + '}'; break;
      case 'extract': cmd = '{"op":"extractPages","pages":' + pages + '}'; break;
      case 'setTitle': cmd = '{"op":"setInfo","key":"Title","value":' + text + '}'; break;
      case 'setAuthor': cmd = '{"op":"setInfo","key":"Author","value":' + text + '}'; break;
      case 'addBookmark': cmd = '{"op":"addBookmark","title":' + text + ',"page":' + pg + '}'; break;
      case 'numberPages': cmd = '{"op":"numberPages","start":0,"to":' + (this.pageCount - 1) +
        ',"style":"decimal","prefix":' + value + ',"first":1}'; break;
      // 批注
      case 'addNote': cmd = '{"op":"addNote","page":' + pg + ',"at":[72,72],"text":' + text +
        ',"author":"PdfCraft"}'; break;
      case 'addHighlight': cmd = '{"op":"addHighlight","page":' + pg + ',"quads":' + quads +
        ',"text":' + text + ',"author":"PdfCraft"}'; break;
      case 'addRect': cmd = '{"op":"addShape","page":' + pg + ',"shape":"rectangle","rect":' + rect +
        ',"text":' + text + '}'; break;
      case 'addOval': cmd = '{"op":"addShape","page":' + pg + ',"shape":"oval","rect":' + rect +
        ',"text":' + text + '}'; break;
      case 'addLine': cmd = '{"op":"addShape","page":' + pg + ',"shape":"line","rect":' + rect +
        ',"text":' + text + '}'; break;
      case 'listAnnotations': cmd = '{"op":"listAnnotations","page":' + pg + '}'; preview = false; break;
      case 'setAnnotationText': cmd = '{"op":"setAnnotationContents","page":' + pg +
        ',"index":' + n + ',"text":' + text + '}'; break;
      case 'replyAnnotation': cmd = '{"op":"replyToAnnotation","page":' + pg + ',"index":' + n +
        ',"text":' + text + '}'; break;
      case 'deleteAnnotation': cmd = '{"op":"deleteAnnotation","page":' + pg + ',"index":' + n + '}'; break;
      // 表单
      case 'addFieldText': cmd = '{"op":"addField","page":' + pg + ',"rect":' + rect +
        ',"kind":"text","name":' + name + '}'; break;
      case 'addFieldMulti': cmd = '{"op":"addField","page":' + pg + ',"rect":' + rect +
        ',"kind":"text","multiline":true,"name":' + name + '}'; break;
      case 'addFieldCheck': cmd = '{"op":"addField","page":' + pg + ',"rect":' + rect +
        ',"kind":"checkbox","name":' + name + '}'; break;
      case 'addFieldDate': cmd = '{"op":"addField","page":' + pg + ',"rect":' + rect +
        ',"kind":"date","name":' + name + '}'; break;
      case 'addFieldCombo': cmd = '{"op":"addField","page":' + pg + ',"rect":' + rect +
        ',"kind":"combo","options":["A","B","C"],"name":' + name + '}'; break;
      case 'addFieldSignature': cmd = '{"op":"addField","page":' + pg + ',"rect":' + rect +
        ',"kind":"signature","name":' + name + '}'; break;
      case 'setFieldValue': cmd = '{"op":"setFieldValue","name":' + name + ',"value":' + value + '}'; break;
      case 'listFields': cmd = '{"op":"listFields"}'; preview = false; break;
      case 'deleteField': cmd = '{"op":"deleteField","name":' + name + '}'; break;
      case 'resetForm': cmd = '{"op":"resetForm"}'; break;
      // 编辑内容
      case 'addText': cmd = '{"op":"addText","page":' + pg + ',"rect":' + rect + ',"text":' + text +
        ',"size":' + n + '}'; break;
      case 'addWatermark': cmd = '{"op":"addWatermark","text":' + text + ',"opacity":0.35}'; break;
      case 'addHeaderFooter': cmd = '{"op":"addHeaderFooter","text":["","","","","' +
        '<<1>> / <<n>>",""],"fontSize":10}'; break;
      case 'removeWatermark': cmd = '{"op":"removeMarks","kind":"watermark"}'; break;
      case 'deleteContent': cmd = '{"op":"deleteContent","page":' + pg + ',"index":' + n + '}'; break;
      // 保护
      case 'encryptAes256':
      case 'encryptAes128': {
        // 明确要求填写并确认密码，避免"加密了但没密码"的静默结果。
        if (this.editPassword === '') {
          this.editMsg = this.t('请先在「用户密码」里输入密码', 'Enter a user password first');
          return;
        }
        // 确认框留空或一致即可；只在两次都填且不一致时才拦截，避免只填一处就加密静默失败。
        if (this.editPassword2 !== '' && this.editPassword2 !== this.editPassword) {
          this.editMsg = this.t('两次输入的密码不一致', 'The two passwords do not match');
          return;
        }
        const algo: string = id === 'encryptAes256' ? 'aes256' : 'aes128';
        const seed: number[] = [];
        for (let i: number = 0; i < 32; i++) { seed.push(Math.floor(Math.random() * 256)); }
        const userPw: string = this.esc(this.editPassword);
        const ownerPw: string = this.esc(this.editOwnerPw === '' ? this.editPassword : this.editOwnerPw);
        cmd = '{"op":"encrypt","algorithm":"' + algo + '","userPassword":' + userPw +
          ',"ownerPassword":' + ownerPw + ',"permissions":-1,"encryptMetadata":true,"seed":' +
          JSON.stringify(seed) + '}';
        preview = false; // 加密后不刷新预览，保存时用全量重写
        break;
      }
      case 'removeEncryption': cmd = '{"op":"removeEncryption"}'; break;
      default: return;
    }
    const ok: boolean = this.execEdit(cmd, preview, gotoPage);
    if (ok && (id === 'encryptAes256' || id === 'encryptAes128')) {
      this.previewPassword = this.editPassword;
      this.editMsg = this.t('已设置密码。请点「另存为」导出加密 PDF；之后打开该文件需要此密码。',
        'Password set. Tap Save as to export the encrypted PDF; it will need this password to open.');
    }
    if (ok && id === 'removeEncryption') {
      this.previewPassword = '';
    }
    } catch (e) {
      this.editMsg = this.t('执行出错：', 'Action failed: ') + String(e);
    }
  }

  private basename(uri: string): string {
    const idx: number = uri.lastIndexOf('/');
    return idx >= 0 ? uri.substring(idx + 1) : uri;
  }

  private async openFile(): Promise<void> {
    this.errMsg = '';
    const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    let uris: string[] = [];
    try {
      uris = await this.docPicker.select(opts);
    } catch (e) {
      this.errMsg = this.t('选择文件出错：', 'Select file error: ') + String(e);
      return;
    }
    if (uris && uris.length > 0) {
      this.loadPdf(uris[0]);
    }
  }

  private async loadPdf(uri: string, password: string = ''): Promise<void> {
    this.errMsg = '';
    this.loading = true;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const rd: number = fs.readSync(file.fd, buf);
      if (rd <= 0) {
        this.errMsg = this.t('文件为空或无法读取', 'File is empty or unreadable');
        return;
      }
      await this.commitPdf(buf, uri, stat.size, password);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadPdf failed: %{public}s', String(e));
      this.errMsg = this.t('打开失败：', 'Open failed: ') + String(e);
    } finally {
      if (file !== null) {
        try { fs.closeSync(file.fd); } catch (ignored) { }
      }
      this.loading = false;
    }
  }

  /** 真正把 PDF 字节挂到界面上；加密文件会先弹密码框（返回 false）。 */
  private async commitPdf(buf: ArrayBuffer, uri: string, size: number, password: string): Promise<boolean> {
    const h: bigint | null = password === '' ? pdfc.open(buf) : pdfc.open(buf, password);
    const count: number = h === null ? 0 : pdfc.pageCount(h);
    if (count <= 0) {
      if (h !== null) { pdfc.close(h); }
      if (pdfc.needsPassword(buf)) {
        this.pendingBytes = buf;
        this.pendingUri = uri;
        this.pendingName = this.basename(uri);
        this.pendingSize = size;
        this.passwordInput = '';
        this.passwordHint = password === ''
          ? this.t('该 PDF 已加密，请输入密码', 'This PDF is encrypted. Enter its password.')
          : this.t('密码不正确，请重试', 'Incorrect password, please try again.');
        this.needPassword = true;
        return false;
      }
      this.errMsg = this.t('无法解析该文件（可能不是有效的 PDF）', 'Cannot parse the file (may not be a valid PDF)');
      return false;
    }
    if (this.hasDoc && this.handle !== null) {
      pdfc.close(this.handle);
    }
    // 文档换了，旧的编辑会话必须丢弃（它基于上一份字节）。
    if (this.editHandle !== null) {
      try { pdfc.editClose(this.editHandle); } catch (e) { }
    }
    this.editHandle = null;
    this.editStateInfo = null;
    this.editMsg = '';
    this.editOpen = false;
    this.docBytes = buf;
    this.docUri = uri;
    this.openPassword = password;
    this.previewPassword = password;
    this.handle = h;
    this.hasDoc = true;
    this.pageCount = count;
    this.curPage = 0;
    this.uiZoom = 1.0;
    this.continuous = false;
    this.docName = this.basename(uri);
    this.sheetOpen = false;
    this.showSearch = false;
    this.saveRecent(uri, this.docName, size, count);
    this.searchResults = null;
    this.matches = [];
    this.curMatch = -1;
    await this.renderCurrent();
    this.loadMeta();
    this.loadOutline();
    return true;
  }

  /** 密码框「打开」：用输入的密码重试。 */
  private async submitPassword(): Promise<void> {
    const buf: ArrayBuffer | null = this.pendingBytes;
    const uri: string = this.pendingUri;
    const size: number = this.pendingSize;
    const pw: string = this.passwordInput;
    this.pendingBytes = null;
    this.needPassword = false;
    if (buf === null) { return; }
    this.loading = true;
    try {
      await this.commitPdf(buf, uri, size, pw);
    } finally {
      this.loading = false;
    }
  }

  private cancelPassword(): void {
    this.needPassword = false;
    this.pendingBytes = null;
    this.passwordInput = '';
    this.errMsg = this.t('已取消打开', 'Open cancelled');
  }

  // ---- 渲染 ---------------------------------------------------------------
  private async renderCurrent(): Promise<void> {
    if (this.handle === null) {
      return;
    }
    this.loading = true;
    this.errMsg = '';
    try {
      const r: RenderedPage | null = pdfc.renderPage(this.handle, this.curPage, RENDER_SCALE);
      if (r === null) {
        this.pixmap = null;
        this.errMsg = `${this.t('第', '')}${this.curPage + 1}${this.t('页渲染失败', ' page render failed')}`;
        return;
      }
      this.imgW = r.width;
      this.imgH = r.height;
      const opt: image.InitializationOptions = {
        size: { width: r.width, height: r.height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      this.pixmap = await image.createPixelMap(r.rgba, opt);
      this.resetScroll();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'renderCurrent failed: %{public}s', String(e));
      this.pixmap = null;
      this.errMsg = this.t('渲染出错：', 'Render error: ') + String(e);
    } finally {
      this.loading = false;
    }
  }

  // 初始化连续视图：只建页索引，具体每页由子组件 ContPage 各自懒渲染。
  private setupContinuous(): void {
    if (this.handle === null) {
      return;
    }
    const idx: number[] = [];
    for (let i = 0; i < this.pageCount; i++) {
      idx.push(i);
    }
    this.contIndices = idx;
  }

  // 连续视图：某页可见比例超过 50% 时把它当作"当前页"，让顶栏页码实时跟随滚动位置。
  private onContVisible(idx: number, ratio: number): void {
    if (ratio > 0.5 && idx >= 0 && idx < this.pageCount && idx !== this.curPage) {
      this.curPage = idx;
    }
  }

  // 渲染第 i 页为 PixelMap（供连续视图的子组件调用）；失败返回 null。
  private async renderContPixel(i: number): Promise<image.PixelMap | null> {
    if (this.handle === null || i < 0 || i >= this.pageCount) {
      return null;
    }
    try {
      const r: RenderedPage | null = pdfc.renderPage(this.handle, i, RENDER_SCALE);
      if (r === null) {
        return null;
      }
      const opt: image.InitializationOptions = {
        size: { width: r.width, height: r.height },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: false
      };
      return await image.createPixelMap(r.rgba, opt);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'renderContPixel failed: %{public}s', String(e));
      return null;
    }
  }

  // 连续视图占位高度用的宽高比（宽/高）
  private contAspect(): number {
    if (this.meta !== null && this.meta.pageSize.length > 0 && this.meta.pageSize[0] && this.meta.pageSize[0][1] > 0) {
      return this.meta.pageSize[0][0] / this.meta.pageSize[0][1];
    }
    return 0.72;
  }

  // ---- 属性 / 书签 --------------------------------------------------------
  private loadMeta(): void {
    if (this.handle === null) {
      return;
    }
    try {
      const s: string = pdfc.metadata(this.handle);
      if (s === '') {
        this.meta = null;
        return;
      }
      const o: Record<string, Object> = JSON.parse(s) as Record<string, Object>;
      const fonts: FontInfo[] = [];
      const fraw: Object[] = (o['fonts'] as Object[]) ?? [];
      for (const f of fraw) {
        const fo = f as Record<string, Object>;
        fonts.push({ name: (fo['name'] as string) ?? '', kind: (fo['kind'] as string) ?? '', embedded: (fo['embedded'] as boolean) ?? false });
      }
      const pageSize: number[][] = [];
      const praw: Object[] = (o['pageSize'] as Object[]) ?? [];
      for (const p of praw) {
        const pa = p as number[];
        if (pa && pa.length >= 2) {
          pageSize.push([pa[0], pa[1]]);
        }
      }
      this.meta = {
        title: (o['title'] as string) ?? '',
        author: (o['author'] as string) ?? '',
        subject: (o['subject'] as string) ?? '',
        keywords: (o['keywords'] as string) ?? '',
        creator: (o['creator'] as string) ?? '',
        producer: (o['producer'] as string) ?? '',
        pdfVersion: (o['pdfVersion'] as string) ?? '',
        fileSize: (o['fileSize'] as number) ?? 0,
        pages: (o['pages'] as number) ?? 0,
        encrypted: (o['encrypted'] as boolean) ?? false,
        fonts: fonts,
        pageSize: pageSize
      };
    } catch (e) {
      this.meta = null;
    }
  }

  private loadOutline(): void {
    if (this.handle === null) {
      return;
    }
    try {
      const s: string = pdfc.outline(this.handle);
      if (s === '') {
        this.outlineItems = [];
        return;
      }
      const o = JSON.parse(s) as OutlineResult;
      this.outlineMore = o.more;
      this.outlineItems = o.items;
    } catch (e) {
      this.outlineItems = [];
    }
  }

  // ---- 搜索 ---------------------------------------------------------------
  private runSearch(): void {
    if (this.handle === null) {
      return;
    }
    const q: string = this.searchInput.trim();
    if (q === '') {
      this.searchResults = null;
      this.matches = [];
      this.curMatch = -1;
      return;
    }
    try {
      const s: string = pdfc.search(this.handle, q, false, false, 2048);
      if (s === '') {
        this.searchResults = null;
        this.matches = [];
        this.curMatch = -1;
        return;
      }
      const r = JSON.parse(s) as SearchResults;
      this.searchResults = r;
      const flat: Match[] = [];
      for (const p of r.pages) {
        if (p.rects) {
          for (const rect of p.rects) {
            flat.push({ page: p.page, rect: rect });
          }
        }
      }
      this.matches = flat;
      this.curMatch = flat.length > 0 ? 0 : -1;
      if (this.curMatch >= 0) {
        this.gotoMatch(0);
      }
    } catch (e) {
      this.searchResults = null;
      this.matches = [];
    }
  }

  private async gotoMatch(idx: number): Promise<void> {
    if (idx < 0 || idx >= this.matches.length) {
      return;
    }
    const m: Match = this.matches[idx];
    this.curMatch = idx;
    this.continuous = false;
    if (m.page !== this.curPage) {
      this.curPage = m.page;
      await this.renderCurrent();
    }
    this.uiZoom = 1.0;
    if (this.imgW <= 0 || this.viewportW <= 0) {
      return;
    }
    // zoom=1 时显示像素 / PDF点 的换算（渲染像素宽 imgW 对应点宽，图片显示宽为视口宽）
    const k: number = this.viewportW / this.imgW;
    const cy: number = (m.rect[1] + m.rect[3]) / 2 * k;
    const contentH: number = this.viewportW * (this.imgH / this.imgW);
    const maxY: number = Math.max(0, contentH - this.viewportH);
    this.innerScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.outerScroller.scrollTo({ xOffset: 0, yOffset: this.clamp(cy - this.viewportH / 2, 0, maxY) });
  }

  private nextMatch(): void {
    if (this.matches.length === 0) {
      return;
    }
    this.gotoMatch((this.curMatch + 1) % this.matches.length);
  }

  private prevMatch(): void {
    if (this.matches.length === 0) {
      return;
    }
    this.gotoMatch((this.curMatch - 1 + this.matches.length) % this.matches.length);
  }

  private gotoOutlinePage(page: number): void {
    if (page < 0 || page >= this.pageCount) {
      return;
    }
    this.continuous = false;
    this.sheetOpen = false;
    this.curPage = page;
    this.renderCurrent();
  }

  // ---- 翻页 / 缩放 --------------------------------------------------------
  private prevPage(): void {
    if (this.curPage > 0) {
      this.curPage--;
      this.renderCurrent();
    }
  }

  private nextPage(): void {
    if (this.curPage < this.pageCount - 1) {
      this.curPage++;
      this.renderCurrent();
    }
  }

  private clamp(v: number, lo: number, hi: number): number {
    if (v < lo) { return lo; }
    if (v > hi) { return hi; }
    return v;
  }

  private setZoom(z: number): void {
    this.uiZoom = this.clamp(z, ZOOM_MIN, ZOOM_MAX);
  }

  private applyZoom(z: number, anchorX: number, anchorY: number): void {
    const old: number = this.uiZoom;
    const nz: number = this.clamp(z, ZOOM_MIN, ZOOM_MAX);
    const ratio: number = nz / old;
    const iw: number = this.viewportW * old;
    const ih: number = iw * (this.imgW > 0 ? this.imgH / this.imgW : 1);
    const ax: number = this.clamp(anchorX, 0, iw);
    const ay: number = this.clamp(anchorY, 0, ih);
    this.uiZoom = nz;
    const osx: number = this.innerScroller.currentOffset().xOffset;
    const osy: number = this.outerScroller.currentOffset().yOffset;
    const nsx: number = this.clamp(osx + ax * (ratio - 1), 0, Math.max(0, iw - this.viewportW));
    const nsy: number = this.clamp(osy + ay * (ratio - 1), 0, Math.max(0, ih - this.viewportH));
    this.innerScroller.scrollTo({ xOffset: nsx, yOffset: 0 });
    this.outerScroller.scrollTo({ xOffset: 0, yOffset: nsy });
  }

  private zoomIn(): void {
    this.applyZoom(this.uiZoom * 1.25, this.viewportW / 2, this.viewportH / 2);
  }

  private zoomOut(): void {
    this.applyZoom(this.uiZoom / 1.25, this.viewportW / 2, this.viewportH / 2);
  }

  private resetZoom(): void {
    this.uiZoom = 1.0;
    this.innerScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.outerScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private resetScroll(): void {
    this.innerScroller.scrollTo({ xOffset: 0, yOffset: 0 });
    this.outerScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private toggleLayout(): void {
    if (this.continuous) {
      this.continuous = false;
    } else {
      this.continuous = true;
      this.setupContinuous();
    }
  }

  private highlight(): Match | null {
    if (this.curMatch < 0 || this.curMatch >= this.matches.length) {
      return null;
    }
    const m: Match = this.matches[this.curMatch];
    if (m.page !== this.curPage) {
      return null;
    }
    return m;
  }

  // ================= 桌面版主布局（对齐原版 ui-egui 的 Acrobat 风格） =================
  // 顶栏(tab strip, 灰) → 模式条(mode bar, 白) → 中间 Row(左工具栏 | 画布/首页 | 右面板栏) → 状态栏
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.titlebar();
        this.modebar();

        Row() {
          if (this.hasDoc) {
            if (this.showActions) {
              this.actionList();
            } else {
              this.leftRail();
            }
          }
          this.centerView();
          if (this.hasDoc) {
            if (this.panelOpen !== '') {
              this.wideRightPanel();
            }
            this.rightRail();
          }
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .clip(true)

        this.statusBar();
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.c().bg)

      // 打开加密 PDF 时的密码框（全屏遮罩）
      if (this.needPassword) {
        this.passwordDialog();
      }

      // 设置 / 关于对话框（全屏遮罩，通用 + 关于两个标签页）
      if (this.showSettings) {
        this.settingsDialog();
      }
    }
    .width('100%')
    .height('100%');
  }

  // ---- 顶栏（tab strip）：灰底，Home / 文档标签 / Open+ / 设置·主题·帮助·语言 ----
  @Builder
  titlebar() {
    Row({ space: 6 }) {
      Image($r('app.media.app_icon')).width(20).height(20).borderRadius(4).margin({ right: 6 });
      // Home（对齐原版 icons::button "house"）
      Text(this.hasDoc ? '⌂' : '⌂')
        .fontSize(17)
        .fontColor(!this.hasDoc ? this.c().accent : this.c().text)
        .width(32).height(28).textAlign(TextAlign.Center)
        .backgroundColor(!this.hasDoc ? this.c().accent_soft : this.c().bar)
        .borderRadius(6)
        .onClick(() => this.goHome());

      // 文档标签（打开时显示；对齐原版 tab：文件图标 + 名称 + 关闭✕）
      if (this.hasDoc) {
        Row({ space: 6 }) {
          Text('📄').fontSize(13).fontColor(this.c().accent);
          Text(this.docName)
            .fontSize(13).fontColor(this.c().text)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 320 });
          Text('✕').fontSize(12).fontColor(this.c().sub).width(18).textAlign(TextAlign.Center)
            .onClick(() => this.goHome());
        }
        .padding({ left: 12, right: 10, top: 4, bottom: 4 })
        .backgroundColor(this.c().bar)
        .border({ width: 1, color: this.c().divider })
        .borderRadius(7);
      }

      // Open +（对齐原版 ghost_button "plus" "Open"）
      Row({ space: 4 }) {
        Text('＋').fontSize(15).fontColor(this.c().text);
        Text(this.t('打开', 'Open')).fontSize(13).fontColor(this.c().text);
      }
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor(this.c().bar)
      .border({ width: 1, color: this.c().border })
      .borderRadius(6)
      .onClick(() => this.openFile());

      Blank();

      // 右侧控件（对齐原版：设置 / 主题 / 帮助 / Discord，这里把 Discord 换成语言切换以保留功能）
      Text('⚙').fontSize(16).fontColor(this.c().text).width(30).height(28).textAlign(TextAlign.Center)
        .onClick(() => this.openSettings('general'));
      Text(this.themeDark ? '☀' : '🌙').fontSize(16).fontColor(this.c().text).width(30).height(28).textAlign(TextAlign.Center)
        .onClick(() => { this.toggleTheme(); });
      Text('？').fontSize(15).fontColor(this.c().text).width(28).height(28).textAlign(TextAlign.Center)
        .onClick(() => this.openSettings('about'));
      Text(this.lang === 'zh' ? 'EN' : '中').fontSize(12).fontColor(this.c().sub)
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .border({ width: 1, color: this.c().border }).borderRadius(5)
        .onClick(() => this.toggleLang());
    }
    .width('100%')
    .padding({ left: 10, right: 12 })
    .height(42)
    .backgroundColor(this.c().titlebar)
    .border({ width: { bottom: 1 }, color: this.c().divider });
  }

  // ---- 模式条（mode bar）：白底，All tools/Edit/Convert/E-Sign + 打印·保存·属性 + 搜索框 ----
  @Builder
  modebar() {
    Row({ space: 8 }) {
      // 模式标签（对齐原版 mode_tab：All tools / Edit / Convert / E-Sign）
      this.modeTab('alltools', this.t('全部工具', 'All tools'));
      this.modeTab('edit', this.t('编辑', 'Edit'));
      this.modeTab('convert', this.t('转换', 'Convert'));
      this.modeTab('esign', this.t('电子签名', 'E-Sign'));

      Text('').width(1).height(22).backgroundColor(this.c().divider);

      if (this.hasDoc) {
        Text('🖨').fontSize(16).fontColor(this.c().text).width(32).height(30).textAlign(TextAlign.Center)
          .onClick(() => this.status(this.t('打印（开发中）', 'Print (not yet available)')));
        Text('💾').fontSize(16).fontColor(this.c().text).width(32).height(30).textAlign(TextAlign.Center)
          .onClick(() => this.saveEdited());
        Text('ⓘ').fontSize(16).fontColor(this.c().text).width(30).height(30).textAlign(TextAlign.Center)
          .onClick(() => this.openPanel('props'));
      }

      Blank();

      // 搜索框（对齐原版 search_box "Find tools and commands"，这里做文本搜索）
      if (this.hasDoc) {
        Row({ space: 6 }) {
          Text('🔍').fontSize(13).fontColor(this.c().sub);
          TextInput({ placeholder: this.t('查找文本…', 'Find text…'), text: this.searchInput })
            .layoutWeight(1).fontSize(13).height(28)
            .backgroundColor(this.c().chip).fontColor(this.c().text)
            .onChange((v: string) => { this.searchInput = v; this.runSearch(); });
          if (this.matches.length > 0) {
            Text(`${this.curMatch + 1}/${this.matches.length}`).fontSize(11).fontColor(this.c().sub).width(34).textAlign(TextAlign.Center);
            Text('↑').fontSize(15).fontColor(this.c().text).onClick(() => this.prevMatch());
            Text('↓').fontSize(15).fontColor(this.c().text).onClick(() => this.nextMatch());
          }
          if (this.searchInput !== '') {
            Text('✕').fontSize(13).fontColor(this.c().sub).onClick(() => {
              this.searchInput = ''; this.matches = []; this.curMatch = -1; this.searchResults = null;
            });
          }
        }
        .width(300)
        .padding({ left: 8, right: 6, top: 2, bottom: 2 })
        .backgroundColor(this.c().chip)
        .border({ width: 1, color: this.c().border })
        .borderRadius(6);
      }
    }
    .width('100%')
    .padding({ left: 12, right: 14, top: 6, bottom: 6 })
    .backgroundColor(this.c().bar)
    .border({ width: { bottom: 1 }, color: this.c().divider });
  }

  // 单个模式标签按钮
  @Builder
  modeTab(key: string, label: string) {
    Text(label)
      .fontSize(14)
      .fontColor(this.mode === key ? this.c().accent : this.c().text)
      .fontWeight(this.mode === key ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.mode === key ? this.c().accent_soft : this.c().bar)
      .borderRadius(6)
      .onClick(() => this.switchMode(key));
  }

  // ---- 左侧工具栏（窄）：五类工具图标（对齐原版 left panel / quick tools）----
  @Builder
  leftRail() {
    Column({ space: 6 }) {
      this.railToolBtn('organize', '▤');
      this.railToolBtn('comment', '✎');
      this.railToolBtn('form', '▣');
      this.railToolBtn('edit', 'A');
      this.railToolBtn('protect', '🔒');
      Blank();
    }
    .width(52)
    .height('100%')
    .padding({ top: 8, bottom: 8 })
    .backgroundColor(this.c().bar)
    .border({ width: { right: 1 }, color: this.c().divider })
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  railToolBtn(key: string, glyph: string) {
    Column({ space: 2 }) {
      Text(glyph).fontSize(18).fontColor(this.editTab === key ? this.c().accent : this.c().icon);
      Text(this.railLabel(key)).fontSize(9).fontColor(this.editTab === key ? this.c().accent : this.c().faint)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width(44);
    }
    .width(46).padding({ top: 6, bottom: 6 })
    .backgroundColor(this.editTab === key ? this.c().accent_soft : this.c().bar)
    .borderRadius(8)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => this.selectCategory(key));
  }

  private railLabel(key: string): string {
    switch (key) {
      case 'organize': return this.t('组织', 'Organize');
      case 'comment': return this.t('批注', 'Comment');
      case 'form': return this.t('表单', 'Form');
      case 'edit': return this.t('编辑', 'Edit');
      case 'protect': return this.t('保护', 'Protect');
      default: return '';
    }
  }

  // ---- 左侧动作面板（宽）：当前工具类的参数 + 全部动作 + 撤销/重做/另存 ----
  @Builder
  actionList() {
    Column() {
      // 头部：返回箭头 + 工具名
      Row({ space: 8 }) {
        Text('‹').fontSize(22).fontColor(this.c().text).width(28).textAlign(TextAlign.Center)
          .onClick(() => { this.showActions = false; });
        Text(this.currentGroupLabel()).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.c().text)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
      }
      .width('100%').padding({ left: 10, right: 12, top: 8, bottom: 8 });

      // 状态 + 当前页
      Text(this.editStatusLine())
        .fontSize(11).fontColor(this.c().sub)
        .width('100%').padding({ left: 14, right: 14, top: 2, bottom: 4 });
      Text(this.t('当前页 ', 'Page ') + (this.curPage + 1))
        .fontSize(11).fontColor(this.c().accent)
        .width('100%').padding({ left: 14, right: 14, top: 0, bottom: 6 });

      // 内容：参数 + 全部动作 + 结果（可滚动）
      Scroll() {
        Column({ space: 12 }) {
          this.editParams();

          Text(this.t('全部功能', 'All actions'))
            .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.c().text)
            .width('100%').textAlign(TextAlign.Start);
          Column({ space: 6 }) {
            ForEach(this.currentActions(), (a: EditAction) => {
              Text(this.t(a.labelZh, a.labelEn))
                .fontSize(12).fontColor(this.c().text)
                .width('100%')
                .padding({ left: 10, right: 10, top: 10, bottom: 10 })
                .backgroundColor(this.c().card)
                .border({ width: 1, color: this.c().divider })
                .borderRadius(8)
                .textAlign(TextAlign.Start)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick(() => { this.runEditAction(a.id); });
            }, (a: EditAction) => `ea_${a.id}`)
          }
          .width('100%');

          if (this.editMsg !== '') {
            Text(this.editMsg)
              .fontSize(12).fontColor(this.c().accent)
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(this.c().chip).borderRadius(8)
              .textAlign(TextAlign.Start);
          }
        }
        .width('100%').padding({ left: 12, right: 12, bottom: 12 });
      }
      .layoutWeight(1).width('100%').scrollBar(BarState.Auto);

      // 底部：撤销 / 重做 / 另存
      Row({ space: 8 }) {
        Text(this.t('↶ 撤销', 'Undo')).fontSize(12).fontColor(this.c().text)
          .layoutWeight(1).padding({ top: 9, bottom: 9 }).textAlign(TextAlign.Center)
          .backgroundColor(this.c().chip).borderRadius(8).onClick(() => this.editUndo());
        Text(this.t('↷ 重做', 'Redo')).fontSize(12).fontColor(this.c().text)
          .layoutWeight(1).padding({ top: 9, bottom: 9 }).textAlign(TextAlign.Center)
          .backgroundColor(this.c().chip).borderRadius(8).onClick(() => this.editRedo());
        Text(this.t('💾 另存', 'Save as')).fontSize(12).fontColor('#FFFFFF')
          .layoutWeight(1.4).padding({ top: 9, bottom: 9 }).textAlign(TextAlign.Center)
          .backgroundColor(this.c().accent).borderRadius(8).onClick(() => this.saveEdited());
      }
      .width('100%').padding({ left: 10, right: 10, top: 8, bottom: 10 })
      .backgroundColor(this.c().bar).border({ width: { top: 1 }, color: this.c().divider });
    }
    .width(300)
    .height('100%')
    .backgroundColor(this.c().panel)
    .border({ width: { right: 1 }, color: this.c().divider });
  }

  // ---- 中间区：无文档 → 首页；有文档 → 画布 ----
  @Builder
  centerView() {
    if (this.hasDoc) {
      Column() {
        // 实时预览条（有文档时常驻顶部，编辑结果一眼可见）
        if (this.pixmap !== null) {
          Row() {
            Image(this.pixmap).height(90).objectFit(ImageFit.Contain).borderRadius(4)
          }
          .width('100%').height(98).padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(this.themeDark ? '#FFFFFF' : '#F8F8FA')
          .justifyContent(FlexAlign.Center)
          .border({ width: { bottom: 1 }, color: this.c().divider });
        }
        if (this.continuous && this.contIndices.length > 0) {
          this.continuousView();
        } else {
          this.pageView();
        }
      }
      .layoutWeight(1).height('100%');
    } else {
      this.welcomeView();
    }
  }

  // ---- 右侧面板栏（窄）：面板切换图标 + 底部翻页/缩放/旋转 ----
  @Builder
  rightRail() {
    Column({ space: 6 }) {
      // 顶部：面板切换（对齐原版 right rail：Comments/Bookmarks/Pages/Fields/Attachments/Signatures/Tags）
      this.railPanelBtn('bookmarks', '📑', this.t('书签', 'Bookmarks'));
      this.railPanelBtn('fields', '▣', this.t('字段', 'Fields'));
      this.railPanelBtn('props', 'ⓘ', this.t('属性', 'Props'));
      this.railPanelBtn('pages', '▤', this.t('页面', 'Pages'));
      Blank();

      // 底部：页面显示/旋转/缩放/翻页（对齐原版 rail_view_menu + 翻页簇）
      Text('⟳').fontSize(17).fontColor(this.c().icon).width(40).height(32).textAlign(TextAlign.Center)
        .borderRadius(6).onClick(() => { this.runEditAction('rot90'); });
      Text(this.continuous ? '⤢' : '⤢').fontSize(16).fontColor(this.c().icon).width(40).height(30).textAlign(TextAlign.Center)
        .backgroundColor(this.continuous ? this.c().accent_soft : this.c().bar)
        .borderRadius(6).onClick(() => this.toggleLayout());
      Text('−').fontSize(18).fontColor(this.c().icon).width(40).height(30).textAlign(TextAlign.Center)
        .borderRadius(6).onClick(() => this.zoomOut());
      Text(`${Math.round(this.uiZoom * 100)}%`).fontSize(11).fontColor(this.c().sub).width(40).height(20).textAlign(TextAlign.Center);
      Text('+').fontSize(18).fontColor(this.c().icon).width(40).height(30).textAlign(TextAlign.Center)
        .borderRadius(6).onClick(() => this.zoomIn());
      Text('‹').fontSize(20).fontColor(this.c().icon).width(40).height(32).textAlign(TextAlign.Center)
        .borderRadius(6).onClick(() => this.prevPage());
      Text('›').fontSize(20).fontColor(this.c().icon).width(40).height(32).textAlign(TextAlign.Center)
        .borderRadius(6).onClick(() => this.nextPage());
    }
    .width(56)
    .height('100%')
    .padding({ top: 8, bottom: 8 })
    .backgroundColor(this.c().bar)
    .border({ width: { left: 1 }, color: this.c().divider })
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  railPanelBtn(key: string, glyph: string, label: string) {
    Column({ space: 2 }) {
      Text(glyph).fontSize(17).fontColor(this.panelOpen === key ? this.c().accent : this.c().icon);
      Text(label).fontSize(9).fontColor(this.panelOpen === key ? this.c().accent : this.c().faint)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width(48);
    }
    .width(50).padding({ top: 6, bottom: 6 })
    .backgroundColor(this.panelOpen === key ? this.c().accent_soft : this.c().bar)
    .borderRadius(8).alignItems(HorizontalAlign.Center)
    .onClick(() => this.openPanel(key));
  }

  // ---- 右侧面板（宽）：书签 / 字段 / 属性 / 页面 ----
  @Builder
  wideRightPanel() {
    Column() {
      Row() {
        Text(this.panelTitle()).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.c().text)
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text('✕').fontSize(13).fontColor(this.c().sub).width(22).textAlign(TextAlign.Center)
          .onClick(() => { this.panelOpen = ''; });
      }
      .width('100%').padding({ left: 14, right: 12, top: 12, bottom: 8 });

      if (this.panelOpen === 'bookmarks') {
        if (this.outlineItems.length === 0) {
          Text(this.t('该文档没有书签', 'No bookmarks in this document')).fontSize(13).fontColor(this.c().sub)
            .width('100%').textAlign(TextAlign.Center).padding({ top: 24, bottom: 24 });
        } else {
          Scroll() {
            Column() {
              ForEach(this.outlineItems, (it: OutlineItem, index: number) => {
                Row() {
                  Text(it.title).fontSize(13).fontColor(this.c().text).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
                  if (it.page >= 0) { Text(`${it.page + 1}`).fontSize(11).fontColor(this.c().sub); }
                }
                .width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
                .backgroundColor(this.curPage === it.page ? this.c().accent_soft : this.c().panel)
                .onClick(() => this.gotoOutlinePage(it.page));
              }, (it: OutlineItem, index: number) => `ol_${index}_${it.title}`)
            }.width('100%');
          }.layoutWeight(1).width('100%').scrollBar(BarState.Auto);
        }
      } else if (this.panelOpen === 'props') {
        this.propsBody();
      } else if (this.panelOpen === 'fields') {
        this.fieldsBody();
      } else {
        // pages
        this.pagesBody();
      }
    }
    .width(300).height('100%')
    .backgroundColor(this.c().panel)
    .border({ width: { right: 1 }, color: this.c().divider });
  }

  private panelTitle(): string {
    switch (this.panelOpen) {
      case 'bookmarks': return this.t('书签 / 大纲', 'Bookmarks / Outline');
      case 'props': return this.t('文档属性', 'Document properties');
      case 'fields': return this.t('表单字段', 'Form fields');
      case 'pages': return this.t('页面', 'Pages');
      default: return '';
    }
  }

  @Builder
  propsBody() {
    if (this.meta === null) {
      Text(this.t('无法读取文档属性', 'Cannot read document properties')).fontSize(13).fontColor(this.c().sub)
        .width('100%').textAlign(TextAlign.Center).padding({ top: 24, bottom: 24 });
    } else {
      Scroll() {
        Column({ space: 8 }) {
          this.metaRow(this.t('标题', 'Title'), this.meta.title);
          this.metaRow(this.t('作者', 'Author'), this.meta.author);
          this.metaRow(this.t('主题', 'Subject'), this.meta.subject);
          this.metaRow(this.t('关键词', 'Keywords'), this.meta.keywords);
          this.metaRow(this.t('生成者', 'Producer'), this.meta.producer);
          this.metaRow(this.t('PDF 版本', 'PDF version'), this.meta.pdfVersion);
          this.metaRow(this.t('文件大小', 'File size'), this.humanSize(this.meta.fileSize));
          this.metaRow(this.t('页数', 'Pages'), `${this.meta.pages}`);
          this.metaRow(this.t('加密', 'Encrypted'), this.meta.encrypted ? this.t('是', 'Yes') : this.t('否', 'No'));
          this.metaRow(this.t('字体', 'Fonts'),
            this.meta.fonts.length === 0 ? this.t('无', 'None') : `${this.meta.fonts.length}`);
        }
        .width('100%').padding({ left: 14, right: 14, top: 6, bottom: 20 });
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto);
    }
  }

  @Builder
  fieldsBody() {
    Column({ space: 10 }) {
      Text(this.t('列出当前文档的表单字段', 'List the form fields in this document'))
        .fontSize(12).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
      Text(this.t('列出字段', 'List fields')).fontSize(13).fontColor('#FFFFFF')
        .width('100%').padding({ top: 10, bottom: 10 }).textAlign(TextAlign.Center)
        .backgroundColor(this.c().accent).borderRadius(8).onClick(() => { this.runEditAction('listFields'); });
      if (this.editMsg !== '') {
        Text(this.editMsg).fontSize(12).fontColor(this.c().text)
          .width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor(this.c().chip).borderRadius(8).textAlign(TextAlign.Start);
      }
    }
    .width('100%').padding({ left: 14, right: 14, top: 6 });
  }

  @Builder
  pagesBody() {
    Column({ space: 10 }) {
      Text(this.t('页面缩略图（连续滚动视图）', 'Page thumbnails (continuous scroll view)'))
        .fontSize(12).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
      Row({ space: 8 }) {
        Text(this.continuous ? this.t('切换到单页', 'Single page') : this.t('连续滚动', 'Continuous'))
          .fontSize(13).fontColor('#FFFFFF').layoutWeight(1).padding({ top: 10, bottom: 10 })
          .textAlign(TextAlign.Center).backgroundColor(this.c().accent).borderRadius(8)
          .onClick(() => this.toggleLayout());
      }
      .width('100%');
      Text(this.t('共 ', 'Total: ') + this.pageCount + this.t(' 页', ' pages'))
        .fontSize(12).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
    }
    .width('100%').padding({ left: 14, right: 14, top: 6 });
  }

  // ---- 状态栏：页面 x/n + 缩放 + 状态消息 ----
  @Builder
  statusBar() {
    Row({ space: 14 }) {
      if (this.hasDoc) {
        Text(this.t('第 ', 'Page ') + (this.curPage + 1) + this.t(' 页 / 共 ', ' of ') + this.pageCount)
          .fontSize(11).fontColor(this.c().sub);
        Text(`${Math.round(this.uiZoom * 100)}%`).fontSize(11).fontColor(this.c().sub);
        if (this.matches.length > 0) {
          Text(this.t('匹配 ', 'Match ') + (this.curMatch + 1) + this.t('/', '/ ') + this.matches.length)
            .fontSize(11).fontColor(this.c().accent);
        }
      } else {
        Text(this.t('本地运行 · 无遥测 · 无需账号', 'Local · no telemetry · no account'))
          .fontSize(11).fontColor(this.c().faint);
      }
      Blank();
      if (this.errMsg !== '') {
        Text(this.errMsg).fontSize(11).fontColor(this.themeDark ? '#ff9a94' : '#c53030')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 640 });
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 5, bottom: 5 })
    .backgroundColor(this.c().bar)
    .border({ width: { top: 1 }, color: this.c().divider });
  }

  @Builder
  sheetBuilder() {
    if (this.sheetKind === 'outline') {
      this.outlineSheet();
    } else {
      this.propsSheet();
    }
  }

  @Builder
  welcomeView() {
    Scroll() {
      Column({ space: 18 }) {
        // ---- 主标题 + 副标语（对齐 home.rs L79-84，左对齐）----
        Column({ space: 6 }) {
          Text(this.t('欢迎使用 PdfCraft', 'Welcome to PdfCraft'))
            .fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.c().text)
            .width('100%').textAlign(TextAlign.Start);
          Text(this.t('开源 PDF 工作台——本地、私密、可脚本化', 'An open-source PDF workbench — local, private, and scriptable.'))
            .fontSize(14).fontColor(this.c().sub)
            .width('100%').textAlign(TextAlign.Start);
        }
        .width('100%');

        // ---- 推荐工具卡容器（对齐 home.rs L115-151：card 底 + 标题 + 工具卡 + 打开文件卡）----
        Column({ space: 12 }) {
          Text(this.t('推荐工具', 'Recommended tools'))
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.c().text)
            .width('100%').textAlign(TextAlign.Start);
          Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row, alignContent: FlexAlign.Start }) {
            ForEach(RECOMMENDED_TOOLS, (t: ToolCardDef) => {
              this.toolCard(t);
            }, (t: ToolCardDef) => `tool_${t.id}`)
            this.openFileCard();
          }
          .width('100%');
        }
        .width('100%')
        .padding(18)
        .backgroundColor(this.c().card)
        .border({ width: 1, color: this.c().border })
        .borderRadius(12);

        // ---- 最近文件（对齐 home.rs L194-259）----
        Text(this.t('最近文件', 'Recent'))
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.c().text)
          .width('100%').textAlign(TextAlign.Start);
        if (this.recentFiles.length > 0) {
          Column() {
            ForEach(this.recentFiles, (r: RecentFile) => {
              this.recentRow(r);
            }, (r: RecentFile) => `rec_${r.uri}`)
          }
          .width('100%')
          .backgroundColor(this.c().card)
          .border({ width: 1, color: this.c().divider })
          .borderRadius(10);
        } else {
          Text(this.t('在 PdfCraft 中打开的文件会显示在这里。把 PDF 拖到任意位置即可打开。',
            'Files you open in PdfCraft appear here. Drop a PDF anywhere to open it.'))
            .fontSize(13).fontColor(this.c().sub)
            .width('100%').textAlign(TextAlign.Start).padding({ top: 2, bottom: 2 });
        }

        // ---- 隐私声明（对齐 home.rs L270-274）----
        Column({ space: 4 }) {
          Text(this.t('隐私', 'Privacy'))
            .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.c().sub)
            .width('100%').textAlign(TextAlign.Start);
          Text(this.t('PdfCraft 离线运行。不收集遥测、无需账号，除非你添加服务提供方，否则不进行任何云端处理。',
            'PdfCraft works offline. No telemetry, no account, and no cloud processing unless you add a provider.'))
            .fontSize(12).fontColor(this.c().sub)
            .width('100%').textAlign(TextAlign.Start);
        }
        .width('100%');

        Column().width('100%').height(16);
      }
      .width('100%')
      .padding({ left: 36, right: 36, top: 28, bottom: 28 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
    .height('100%')
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor(this.c().bg)
  }

  // 工具卡（对齐 home.rs tool_card 190×104：彩色图标 + 标题 + 描述(2 行) + "Use now"）
  @Builder
  toolCard(t: ToolCardDef) {
    Column() {
      Row({ space: 10 }) {
        Text(this.toolGlyph(t.id))
          .fontSize(15).fontColor('#FFFFFF')
          .width(30).height(30).borderRadius(7)
          .backgroundColor(t.hue).textAlign(TextAlign.Center);
        Text(this.t(t.labelZh, t.labelEn))
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.c().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
      }
      .width('100%');
      Text(this.t(t.descZh, t.descEn))
        .fontSize(11).fontColor(this.c().sub)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').margin({ top: 8 })
        .textAlign(TextAlign.Start);
      Text(this.t('立即使用', 'Use now'))
        .fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.c().accent)
        .width('100%').textAlign(TextAlign.Start);
    }
    .width(190).height(104)
    .padding(14)
    .backgroundColor(this.c().card)
    .border({ width: 1, color: this.c().divider })
    .borderRadius(10)
    .margin({ right: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .onClick(() => { this.openTool(t.id); });
  }

  // 打开文件卡（对齐 home.rs L133-149：170×104，folder-open 图标 + "Open file"）
  @Builder
  openFileCard() {
    Column({ space: 12 }) {
      Text('📂').fontSize(30);
      Text(this.t('打开文件', 'Open file'))
        .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.c().text);
    }
    .width(170).height(104)
    .padding(14)
    .backgroundColor(this.c().bg)
    .border({ width: 1, color: this.c().divider })
    .borderRadius(10)
    .margin({ right: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.openFile(); });
  }

  private toolGlyph(id: string): string {
    switch (id) {
      case 'organize': return '▤';
      case 'comment': return '✎';
      case 'form': return '▣';
      case 'edit': return 'A';
      case 'protect': return '🔒';
      default: return '◆';
    }
  }

  // ---- 编辑工具：全屏面板（顶栏 / 分类 / 参数 / 全部动作 / 底栏）----------------
  // 之前用 bindSheet + 百分比高度，抽屉测量会把控件挤到屏幕底部、动作列表被截断，
  // 导致「列出字段」「添加批注」等按钮看不见。现在改成确定高度的全屏 Column：
  // 顶栏固定、中间唯一一个 Scroll 用 layoutWeight(1) 吃掉剩余高度、底栏固定。
  @Builder
  editPanel() {
    Column() {
      // 顶栏
      Row({ space: 8 }) {
        Text('‹').fontSize(24).fontColor(this.c().text).width(36).height(36).textAlign(TextAlign.Center)
          .onClick(() => { this.editOpen = false; });
        Column({ space: 2 }) {
          Text(this.t('编辑 PDF', 'Edit PDF')).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.c().text);
          Text(this.t('工具：', 'Tool: ') + this.currentGroupLabel())
            .fontSize(11).fontColor(this.c().sub)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        }.alignItems(HorizontalAlign.Start).layoutWeight(1);
        Text(this.t('关闭', 'Close')).fontSize(12).fontColor(this.c().sub)
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .onClick(() => { this.editOpen = false; });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(this.c().bar)
      .border({ width: { bottom: 1 }, color: this.c().divider });

      // 状态 + 当前页（插入/批注都以此页为准）
      Text(this.editStatusLine() + ' · ' + this.t('当前页 ', 'Page ') + (this.curPage + 1))
        .fontSize(11).fontColor(this.c().sub)
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 });

      // 实时预览：编辑结果直接显示在这里，能立刻看到插入的空白页 / 批注是否生效。
      if (this.pixmap !== null) {
        Row() {
          Image(this.pixmap)
            .height(150)
            .objectFit(ImageFit.Contain)
            .borderRadius(6)
        }
        .width('100%').height(162)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: this.c().divider })
        .borderRadius(6)
        .padding({ top: 4, bottom: 4 })
        .justifyContent(FlexAlign.Center)
      }

      // 五类工具切换
      Scroll() {
        Row({ space: 8 }) {
          ForEach(EDIT_GROUPS, (g: EditGroup) => {
            Text(this.t(g.labelZh, g.labelEn))
              .fontSize(12)
              .fontColor(this.editTab === g.id ? '#FFFFFF' : this.c().text)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(this.editTab === g.id ? g.hue : this.c().chip)
              .borderRadius(16)
              .onClick(() => { this.editTab = g.id; this.editMsg = ''; });
          }, (g: EditGroup) => `eg_${g.id}`)
        }.padding({ left: 16, right: 16 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .padding({ top: 2, bottom: 8 });

      // 唯一的内容滚动区：参数 + 全部动作 + 结果，都能滚到
      Scroll() {
        Column({ space: 12 }) {
          this.editParams();

          Text(this.t('全部功能', 'All actions'))
            .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.c().text)
            .width('100%').textAlign(TextAlign.Start);
          Grid() {
            ForEach(this.currentActions(), (a: EditAction) => {
              GridItem() {
                Text(this.t(a.labelZh, a.labelEn))
                  .fontSize(12).fontColor(this.c().text)
                  .width('100%')
                  .padding({ left: 10, right: 10, top: 12, bottom: 12 })
                  .backgroundColor(this.c().card)
                  .border({ width: 1, color: this.c().divider })
                  .borderRadius(8)
                  .textAlign(TextAlign.Center)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => { this.runEditAction(a.id); });
              }
            }, (a: EditAction) => `ea_${a.id}`)
          }
          .columnsTemplate('1fr 1fr')
          .rowsGap(8).columnsGap(8)
          .width('100%');

          if (this.editMsg !== '') {
            Text(this.editMsg)
              .fontSize(12).fontColor(this.c().accent)
              .width('100%')
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(this.c().chip)
              .borderRadius(8);
          }
          Text(this.t('提示：修改后点「另存为」才会写入文件；撤销 / 重做最多 60 步。',
            'Tip: tap Save as to write changes to a file; Undo/Redo keeps up to 60 steps.'))
            .fontSize(11).fontColor(this.c().faint).width('100%');
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 });
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto);

      // 底栏固定
      Row({ space: 8 }) {
        Text(this.t('↶ 撤销', '↶ Undo')).fontSize(13).fontColor(this.c().text)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.c().chip).borderRadius(8)
          .onClick(() => this.editUndo());
        Text(this.t('↷ 重做', '↷ Redo')).fontSize(13).fontColor(this.c().text)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.c().chip).borderRadius(8)
          .onClick(() => this.editRedo());
        Text(this.t('💾 另存为', '💾 Save as')).fontSize(13).fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.c().accent).borderRadius(8)
          .onClick(() => { this.saveEdited(); });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 18 })
      .backgroundColor(this.c().bar)
      .border({ width: { top: 1 }, color: this.c().divider })
      .justifyContent(FlexAlign.SpaceBetween);
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.c().bg);
  }

  /** 按工具分类显示真正用得到的输入项——密码、批注内容、字段名都有明确位置。 */
  @Builder
  editParams() {
    Column({ space: 10 }) {
      Text(this.t('参数', 'Parameters'))
        .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.c().text)
        .width('100%').textAlign(TextAlign.Start);

      if (this.editTab !== 'protect') {
        Column({ space: 4 }) {
          Text(this.t('作用页码（1 基，如 1,3-5；留空 = 当前页）', 'Pages (1-based, e.g. 1,3-5; blank = current page)'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: '1,3-5', text: this.editPages })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editPages = v; });
        }.width('100%');
      }

      if (this.editTab === 'organize') {
        Column({ space: 4 }) {
          Text(this.t('标题 / 书签文字（设置标题、设置作者、添加书签用）', 'Title / bookmark text'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: this.t('输入文字', 'Enter text'), text: this.editText })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editText = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('页码前缀（设置页码样式用）', 'Page number prefix'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: 'A-', text: this.editValue })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editValue = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('数值：移动所选页的目标位置（1 基）', 'Number: destination for Move pages (1-based)'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: '1', text: this.editNum })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editNum = v; });
        }.width('100%');
        Text(this.t('插入空白页会插入到「当前页」的前面或后面，尺寸跟随当前页，插入后自动跳到新页。',
          'Blank pages are inserted before/after the current page, matching its size; the view jumps to the new page.'))
          .fontSize(11).fontColor(this.c().faint).width('100%');
      } else if (this.editTab === 'comment') {
        Column({ space: 4 }) {
          Text(this.t('批注内容（添加便签 / 高亮 / 形状、修改内容、回复批注都用这个）', 'Comment text'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: this.t('写点什么…', 'Write a comment…'), text: this.editText })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editText = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('数值：批注索引（「列出本页批注」返回的 [n]）', 'Number: comment index from List annotations'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: '0', text: this.editNum })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editNum = v; });
        }.width('100%');
        Text(this.t('先点「添加便签 / 添加高亮」，再点「列出本页批注」即可看到刚添加的批注。',
          'Tap Add sticky note / Add highlight first, then List annotations to see it.'))
          .fontSize(11).fontColor(this.c().faint).width('100%');
      } else if (this.editTab === 'form') {
        Column({ space: 4 }) {
          Text(this.t('字段名（留空则自动命名；填写 / 删除字段也用这个名字）', 'Field name'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: 'Field1', text: this.editText })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editText = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('字段值（填写字段用）', 'Field value'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: this.t('要填入的内容', 'Value to fill in'), text: this.editValue })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editValue = v; });
        }.width('100%');
        Text(this.t('先点「文本域 / 复选框」等添加字段，再点「列出字段」查看全部字段。',
          'Add a field first, then tap List fields to see all fields.'))
          .fontSize(11).fontColor(this.c().faint).width('100%');
      } else if (this.editTab === 'edit') {
        Column({ space: 4 }) {
          Text(this.t('文本 / 水印文字（添加文本、添加水印用）', 'Text / watermark text'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: 'DRAFT', text: this.editText })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editText = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('数值：字号 / 添加内容的索引', 'Number: font size / added-content index'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: '12', text: this.editNum })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .onChange((v: string) => { this.editNum = v; });
        }.width('100%');
      } else {
        // 保护 PDF：四个密码各司其职，避免「加密了却没地方输密码」。
        Column({ space: 4 }) {
          Text(this.t('① 用户密码 *（打开加密后文件时需要输入）', '① User password * (required to open the saved file)'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: this.t('必填', 'Required'), text: this.editPassword })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .type(InputType.Password)
            .onChange((v: string) => { this.editPassword = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('② 确认密码 *', '② Confirm password *'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: this.t('再输一次', 'Repeat the password'), text: this.editPassword2 })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .type(InputType.Password)
            .onChange((v: string) => { this.editPassword2 = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('③ 所有者密码（可留空，留空则与用户密码相同）', '③ Owner password (optional, defaults to user password)'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: this.t('可留空', 'Optional'), text: this.editOwnerPw })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .type(InputType.Password)
            .onChange((v: string) => { this.editOwnerPw = v; });
        }.width('100%');
        Column({ space: 4 }) {
          Text(this.t('④ 当前文档密码（打开「已经加密」的文件时用，不是新密码）', '④ Current file password (to unlock an already-encrypted file)'))
            .fontSize(11).fontColor(this.c().sub).width('100%').textAlign(TextAlign.Start);
          TextInput({ placeholder: this.t('已加密文件才需要', 'Only for encrypted files'), text: this.openPassword })
            .fontSize(13).height(38).width('100%')
            .backgroundColor(this.c().card).borderRadius(8)
            .type(InputType.Password)
            .onChange((v: string) => { this.openPassword = v; });
        }.width('100%');
        Text(this.t('步骤：填好 ①② → 点「AES-256 加密」→ 点右下角「另存为」。打开导出的文件时会要求输入 ①。',
          'Steps: fill ①② → tap AES-256 Encrypt → Save as. The exported file will ask for ① when opened.'))
          .fontSize(11).fontColor(this.c().faint).width('100%');
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.c().panel)
    .border({ width: 1, color: this.c().divider })
    .borderRadius(10)
    .alignItems(HorizontalAlign.Start);
  }

  /** 打开加密 PDF 的密码框（半透明遮罩 + 居中卡片）。 */
  @Builder
  passwordDialog() {
    Column() {
      Column({ space: 12 }) {
        Text(this.t('需要密码', 'Password required'))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.c().text)
          .width('100%').textAlign(TextAlign.Start);
        Text(this.pendingName).fontSize(12).fontColor(this.c().sub)
          .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.passwordHint).fontSize(12).fontColor(this.c().sub).width('100%');
        TextInput({ placeholder: this.t('输入密码', 'Enter password'), text: this.passwordInput })
          .fontSize(14).height(42).width('100%')
          .backgroundColor(this.c().chip).borderRadius(8)
          .type(InputType.Password)
          .onChange((v: string) => { this.passwordInput = v; });
        Row({ space: 10 }) {
          Text(this.t('取消', 'Cancel')).fontSize(13).fontColor(this.c().text)
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .backgroundColor(this.c().chip).borderRadius(8)
            .onClick(() => this.cancelPassword());
          Text(this.t('打开', 'Open')).fontSize(13).fontColor('#FFFFFF')
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .backgroundColor(this.c().accent).borderRadius(8)
            .onClick(() => { this.submitPassword(); });
        }.width('100%').justifyContent(FlexAlign.End);
      }
      .width('88%')
      .padding(18)
      .backgroundColor(this.c().panel)
      .borderRadius(14);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  /** 设置面板里的一行标签（左：标签文字）。 */
  @Builder
  settingLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(this.c().faint)
      .width('100%')
      .textAlign(TextAlign.Start)
      .margin({ bottom: 6 });
  }

  /** 设置面板里的分段选择按钮（选中高亮 accent_soft + accent，未选 chip）。 */
  @Builder
  segBtn(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(active ? this.c().accent : this.c().text)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .backgroundColor(active ? this.c().accent_soft : this.c().chip)
      .borderRadius(8)
      .onClick(() => { onTap(); });
  }

  // 设置 / 关于对话框（通用 + 关于两个标签页）
  @Builder
  settingsDialog() {
    Column() {
      Column({ space: 0 }) {
        // 顶栏：标题 + 关闭
        Row({ space: 8 }) {
          Text(this.settingsTab === 'about'
            ? this.t('关于', 'About')
            : this.t('设置', 'Settings'))
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.c().text)
            .layoutWeight(1);
          Text('✕').fontSize(14).fontColor(this.c().sub).width(26).height(26)
            .textAlign(TextAlign.Center).borderRadius(6)
            .onClick(() => this.closeSettings());
        }
        .width('100%')
        .padding({ left: 18, right: 14, top: 14, bottom: 10 });

        // 标签页切换：通用 / 关于
        Row({ space: 8 }) {
          this.segBtn(this.t('通用', 'General'), this.settingsTab === 'general',
            () => { this.settingsTab = 'general'; });
          this.segBtn(this.t('关于', 'About'), this.settingsTab === 'about',
            () => { this.settingsTab = 'about'; });
        }
        .width('100%')
        .padding({ left: 18, right: 18, bottom: 4 });

        Text('').width('100%').height(1).backgroundColor(this.c().divider)
          .margin({ left: 18, right: 18, top: 8, bottom: 4 });

        // 内容区
        Column({ space: 14 }) {
          if (this.settingsTab === 'general') {
            // 外观（浅色 / 深色）
            this.settingLabel(this.t('外观', 'Appearance'));
            Row({ space: 8 }) {
              this.segBtn(this.t('浅色', 'Light'), !this.themeDark,
                () => { if (this.themeDark) { this.toggleTheme(); } });
              this.segBtn(this.t('深色', 'Dark'), this.themeDark,
                () => { if (!this.themeDark) { this.toggleTheme(); } });
            }.width('100%');

            // 语言（中文 / English）
            this.settingLabel(this.t('语言', 'Language'));
            Row({ space: 8 }) {
              this.segBtn(this.t('中文', 'Chinese'), this.lang === 'zh',
                () => { if (this.lang !== 'zh') { this.toggleLang(); } });
              this.segBtn('English', this.lang === 'en',
                () => { if (this.lang !== 'en') { this.toggleLang(); } });
            }.width('100%');

            // 阅读视图（单页 / 连续）
            this.settingLabel(this.t('阅读视图', 'Reading view'));
            Row({ space: 8 }) {
              this.segBtn(this.t('单页', 'Single page'), !this.continuous,
                () => { this.setContinuous(false); });
              this.segBtn(this.t('连续', 'Continuous'), this.continuous,
                () => { this.setContinuous(true); });
            }.width('100%');

            // 缩放
            this.settingLabel(this.t('缩放', 'Zoom'));
            Row({ space: 8 }) {
              Text('−').fontSize(16).fontColor(this.c().text)
                .width(40).textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
                .backgroundColor(this.c().chip).borderRadius(8)
                .onClick(() => this.zoomOut());
              Text(`${Math.round(this.uiZoom * 100)}%`)
                .fontSize(14).fontColor(this.c().text)
                .layoutWeight(1).textAlign(TextAlign.Center);
              Text('＋').fontSize(16).fontColor(this.c().text)
                .width(40).textAlign(TextAlign.Center)
                .padding({ top: 8, bottom: 8 })
                .backgroundColor(this.c().chip).borderRadius(8)
                .onClick(() => this.zoomIn());
              Text(this.t('重置', 'Reset')).fontSize(13).fontColor(this.c().sub)
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .backgroundColor(this.c().chip).borderRadius(8)
                .onClick(() => this.resetZoom());
            }.width('100%');
          } else {
            // 关于页：应用名 + 版本
            Column({ space: 4 }) {
              Image($r('app.media.app_icon'))
                .width(60).height(60).borderRadius(14)
                .objectFit(ImageFit.Cover).margin({ bottom: 4 });
              Text(APP_NAME).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.c().text);
              Text(this.t('版本', 'Version') + ' ' + APP_VERSION)
                .fontSize(13).fontColor(this.c().accent)
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                .backgroundColor(this.c().accent_soft).borderRadius(10);
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ bottom: 4 });

            // 信息行
            Row({ space: 10 }) {
              Text(this.t('渲染引擎', 'Engine'))
                .fontSize(13).fontColor(this.c().sub).width(70).textAlign(TextAlign.Start);
              Text(this.t('纯 Rust（hayro + vello + lopdf）', 'Pure Rust (hayro + vello + lopdf)'))
                .fontSize(13).fontColor(this.c().text).layoutWeight(1).textAlign(TextAlign.Start);
            }.width('100%');
            Row({ space: 10 }) {
              Text(this.t('平台', 'Platform'))
                .fontSize(13).fontColor(this.c().sub).width(70).textAlign(TextAlign.Start);
              Text('HarmonyOS NEXT (API 26)').fontSize(13).fontColor(this.c().text)
                .layoutWeight(1).textAlign(TextAlign.Start);
            }.width('100%');
            Row({ space: 10 }) {
              Text(this.t('包名', 'Bundle'))
                .fontSize(13).fontColor(this.c().sub).width(70).textAlign(TextAlign.Start);
              Text(APP_BUNDLE).fontSize(13).fontColor(this.c().text)
                .layoutWeight(1).textAlign(TextAlign.Start);
            }.width('100%');
            Row({ space: 10 }) {
              Text(this.t('来源', 'Source'))
                .fontSize(13).fontColor(this.c().sub).width(70).textAlign(TextAlign.Start);
              Text('github.com/storytold/pdfcraft').fontSize(13).fontColor(this.c().text)
                .layoutWeight(1).textAlign(TextAlign.Start);
            }.width('100%');

            Text('').width('100%').height(1).backgroundColor(this.c().divider)
              .margin({ top: 4, bottom: 2 });

            // 已实现的功能列表
            Text(this.t('已实现的功能', 'Available features'))
              .fontSize(12).fontColor(this.c().faint).width('100%').textAlign(TextAlign.Start);
            Text(this.t(
              '阅读（单页 / 连续 · 缩放 · 搜索 · 书签）\n编辑 / 转换 / 电子签名\n文档属性 · 表单 · 保护加密\n最近文件 · 深浅主题 · 中/英双语',
              'Read (single / continuous · zoom · search · bookmarks)\nEdit / Convert / E-Sign\nDocument properties · Forms · Protect\nRecent files · Light & Dark theme · Chinese / English'
            ))
              .fontSize(13).fontColor(this.c().text).width('100%').textAlign(TextAlign.Start);
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 14, bottom: 16 });

        // 底部：确定
        Row() {
          Text(this.t('完成', 'Done'))
            .fontSize(14).fontColor('#FFFFFF')
            .padding({ left: 26, right: 26, top: 10, bottom: 10 })
            .backgroundColor(this.c().accent).borderRadius(8)
            .onClick(() => this.closeSettings());
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ left: 18, right: 18, top: 4, bottom: 16 });
      }
      .width('88%')
      .constraintSize({ maxHeight: '86%' })
      .backgroundColor(this.c().panel)
      .borderRadius(14);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  // 最近文件行（对齐 home.rs L210-259：文件图标红 #E03E3E + 文件名 + 页数/大小）
  @Builder
  recentRow(r: RecentFile) {
    Row({ space: 10 }) {
      Text('📄').fontSize(18);
      Column({ space: 2 }) {
        Text(r.name)
          .fontSize(13).fontColor(this.c().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').textAlign(TextAlign.Start);
        Text(`${r.pages} ${r.pages === 1 ? 'page' : 'pages'} · ${this.humanSize(r.size)}`)
          .fontSize(11).fontColor(this.c().faint)
          .width('100%').textAlign(TextAlign.Start);
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .onClick(() => this.openRecent(r))
      .border({ width: { bottom: 1 }, color: this.c().divider });
  }

  private toast(msg: string): void {
    hilog.info(DOMAIN, TAG, 'toast: %{public}s', msg);
    this.errMsg = msg;
    setTimeout(() => { this.errMsg = ''; }, 2500);
  }

  @Builder
  pageView() {
    if (this.pixmap !== null) {
      Scroll(this.outerScroller) {
        Scroll(this.innerScroller) {
          Stack({ alignContent: Alignment.TopStart }) {
            Image(this.pixmap)
              .width(`${this.uiZoom * 100}%`)
              .aspectRatio(this.imgW > 0 ? this.imgW / this.imgH : 1)
              .objectFit(ImageFit.Fill)
              .backgroundColor('#000000');
            if (this.highlight() !== null) {
              this.matchOverlay();
            }
          }
          .gesture(
            PinchGesture()
              .onActionStart(() => { this.pinchBase = this.uiZoom; })
              .onActionUpdate((e) => {
                let sx: number = 0;
                let sy: number = 0;
                let n: number = 0;
                for (const f of e.fingerList) {
                  sx += f.localX;
                  sy += f.localY;
                  n++;
                }
                if (n > 0) {
                  this.applyZoom(this.pinchBase * e.scale, sx / n, sy / n);
                } else {
                  this.applyZoom(this.pinchBase * e.scale, this.viewportW / 2, this.viewportH / 2);
                }
              })
          )
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Auto)
        .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .onAreaChange((_o: Area, n: Area) => {
        this.viewportW = Number(n.width);
        this.viewportH = Number(n.height);
      })
    } else {
      Column({ space: 12 }) {
        if (this.loading) {
          LoadingProgress().width(44).height(44)
        }
        Text(this.errMsg !== '' ? this.errMsg : this.t('加载页面…', 'Loading page…'))
          .fontSize(13).fontColor(this.errMsg !== '' ? '#e06c60' : this.c().sub);
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center);
    }
  }

  @Builder
  matchOverlay() {
    if (this.highlight() !== null) {
      Rect()
        .width(this.hlSize(0))
        .height(this.hlSize(1))
        .fill('rgba(255,214,0,0.45)')
        .stroke('#ffd600')
        .strokeWidth(1.5)
        .position({ x: this.hlRect(0), y: this.hlRect(1) });
    }
  }

  // 显示像素 / PDF点 的换算：渲染像素(imgW/imgH)与点成正比，图片显示宽 = 视口宽 × 缩放。
  // 高亮矩形（页点、左上原点 y 向下）乘以它就落在显示图片的正确位置。
  private dispK(): number {
    if (this.imgW > 0 && this.viewportW > 0) {
      return (this.viewportW * this.uiZoom) / this.imgW;
    }
    return 0;
  }

  private hlRect(i: number): number {
    const m: Match = this.matches[this.curMatch];
    return m.rect[i] * this.dispK();
  }

  private hlSize(i: number): number {
    const m: Match = this.matches[this.curMatch];
    return (m.rect[i + 2] - m.rect[i]) * this.dispK();
  }

  @Builder
  continuousView() {
    Scroll(this.outerScroller) {
      Column({ space: 10 }) {
        ForEach(this.contIndices, (i: number) => {
          ContPage({
            aspect: this.contAspect(),
            renderFn: () => this.renderContPixel(i),
            index: i,
            onPage: (idx: number, ratio: number) => { this.onContVisible(idx, ratio); }
          });
        }, (i: number) => `cp_${i}_r${this.contRev}`)
      }
      .width('100%')
      .padding({ top: 8, bottom: 16 });
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring)
    .onAreaChange((_o: Area, n: Area) => {
      this.viewportW = Number(n.width);
      this.viewportH = Number(n.height);
    })
    // 实时页码：每次滚动结束后按偏移计算「视口中心所在页」，即时更新左下角页码
    .onDidScroll(() => {
      this.updateCurPageFromScroll();
    })
  }

  // 连续视图：用当前滚动偏移推算可见的「主」页（以视口中心为准），比每页可见阈值触发更及时。
  private updateCurPageFromScroll(): void {
    if (this.pageCount <= 0 || this.viewportW <= 0) {
      return;
    }
    const y: number = this.outerScroller.currentOffset().yOffset;
    const rowH: number = this.viewportW * this.contAspect() + 10; // 每页高 + 10 间距
    if (rowH <= 0) {
      return;
    }
    const center: number = y + (this.viewportH * 0.5) - 8; // -8 为 Column 顶部内边距
    let p: number = Math.floor(center / rowH);
    if (p < 0) {
      p = 0;
    }
    if (p > this.pageCount - 1) {
      p = this.pageCount - 1;
    }
    if (p !== this.curPage) {
      this.curPage = p;
    }
  }

  @Builder
  bottomBar() {
    Row({ space: 8 }) {
      Text('‹').fontSize(20).fontColor(this.c().text).width(38).textAlign(TextAlign.Center).onClick(() => this.prevPage());
      Text('›').fontSize(20).fontColor(this.c().text).width(38).textAlign(TextAlign.Center).onClick(() => this.nextPage());
      Text(`${Math.round(this.uiZoom * 100)}%`).fontSize(12).fontColor(this.c().sub).width(44).textAlign(TextAlign.Center);
      Text('−').fontSize(18).fontColor(this.c().text).width(38).textAlign(TextAlign.Center).onClick(() => this.zoomOut());
      Text('1:1').fontSize(12).fontColor(this.c().sub).width(38).textAlign(TextAlign.Center).onClick(() => this.resetZoom());
      Text('+').fontSize(18).fontColor(this.c().text).width(38).textAlign(TextAlign.Center).onClick(() => this.zoomIn());
      Blank();
      Text(this.continuous ? this.t('单页', 'Single') : this.t('连续', 'Continuous'))
        .fontSize(12)
        .fontColor(this.c().accent)
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(this.c().chip)
        .borderRadius(14)
        .onClick(() => this.toggleLayout());
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.c().bar)
    .border({ width: { top: 1 }, color: this.c().divider })
  }

  @Builder
  outlineSheet() {
    Column() {
      Text(this.t('书签 / 大纲', 'Bookmarks / Outline')).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.c().text)
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 });
      if (this.outlineItems.length === 0) {
        Text(this.t('该文档没有书签', 'No bookmarks in this document')).fontSize(13).fontColor(this.c().sub)
          .width('100%').textAlign(TextAlign.Center).padding({ top: 20, bottom: 30 });
      } else {
        Scroll() {
          Column() {
            ForEach(this.outlineItems, (it: OutlineItem, index: number) => {
              Row() {
                Text(it.title)
                  .fontSize(14)
                  .fontColor(this.c().text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1);
                if (it.page >= 0) {
                  Text(`${it.page + 1}`).fontSize(11).fontColor(this.c().sub);
                }
              }
              .width('100%')
              .padding({ left: 28, right: 16, top: 11, bottom: 11 })
              .onClick(() => this.gotoOutlinePage(it.page));
            }, (it: OutlineItem, index: number) => `ol_${index}_${it.title}`)
          }
          .width('100%');
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto);
      }
    }
    .width('100%')
    .constraintSize({ maxHeight: 480 })
  }

  @Builder
  propsSheet() {
    Column() {
      Text(this.t('文档属性', 'Document properties')).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.c().text)
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 });
      if (this.meta === null) {
        Text(this.t('无法读取文档属性', 'Cannot read document properties')).fontSize(13).fontColor(this.c().sub)
          .width('100%').textAlign(TextAlign.Center).padding({ top: 20, bottom: 30 });
      } else {
        Scroll() {
          Column({ space: 10 }) {
            this.metaRow(this.t('标题', 'Title'), this.meta.title);
            this.metaRow(this.t('作者', 'Author'), this.meta.author);
            this.metaRow(this.t('主题', 'Subject'), this.meta.subject);
            this.metaRow(this.t('关键词', 'Keywords'), this.meta.keywords);
            this.metaRow(this.t('生成者', 'Producer'), this.meta.producer);
            this.metaRow(this.t('PDF 版本', 'PDF version'), this.meta.pdfVersion);
            this.metaRow(this.t('文件大小', 'File size'), this.humanSize(this.meta.fileSize));
            this.metaRow(this.t('页数', 'Pages'), `${this.meta.pages}`);
            this.metaRow(this.t('加密', 'Encrypted'), this.meta.encrypted ? this.t('是', 'Yes') : this.t('否', 'No'));
            this.metaRow(this.t('字体', 'Fonts'),
              this.meta.fonts.length === 0 ? this.t('无', 'None') : `${this.meta.fonts.length} ${this.t('个', '')}`);
            if (this.meta.fonts.length > 0) {
              ForEach(this.meta.fonts, (f: FontInfo, index: number) => {
                Row({ space: 8 }) {
                  Text(f.name).fontSize(12).fontColor(this.c().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1);
                  Text(f.embedded ? this.t('已嵌入', 'Embedded') : this.t('未嵌入', 'Not embedded'))
                    .fontSize(11).fontColor(f.embedded ? this.c().sub : '#e06c60');
                }
                .width('100%')
                .padding({ left: 28, top: 2, bottom: 2 });
              }, (f: FontInfo, index: number) => `ft_${index}_${f.name}`)
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 20 });
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto);
      }
    }
    .width('100%')
    .constraintSize({ maxHeight: 520 })
  }

  @Builder
  metaRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(this.c().sub)
        .width(72);
      Text(value === '' ? '—' : value)
        .fontSize(13)
        .fontColor(this.c().text)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%');
  }

  private humanSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
}

// 连续视图的单页：独立组件，进入可视区才渲染并缓存（互不影响、无共享数组竞态）。
@Component
struct ContPage {
  aspect: number = 0.72;
  index: number = 0;
  renderFn: () => Promise<image.PixelMap | null> = () => Promise.resolve(null);
  onPage: (i: number, r: number) => void = () => {};
  @State pm: image.PixelMap | null = null;

  private async load(): Promise<void> {
    if (this.pm !== null) {
      return;
    }
    const r: image.PixelMap | null = await this.renderFn();
    this.pm = r;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pm !== null) {
        Image(this.pm)
          .width('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor('#000000');
      } else {
        Column() {
          LoadingProgress().width(32).height(32)
        }
        .width('100%')
        .aspectRatio(this.aspect)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#000000');
      }
    }
    .width('100%')
    .onVisibleAreaChange([0.0, 0.1], (_isExpanding: boolean, ratio: number) => {
      if (ratio > 0.1) {
        this.load();
      }
      this.onPage(this.index, ratio);
    });
  }
}
