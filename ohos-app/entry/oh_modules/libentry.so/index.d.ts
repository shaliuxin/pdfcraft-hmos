// libentry.so 的类型声明（PdfCraft HarmonyOS port）。
//
// 必须与 napi_bridge.cpp 里 napi_property_descriptor 的名字、参数个数完全一致
// （ArkTS 静态检查，改一处要同步这里）。

export interface PdfcNative {
  // 打开一份 PDF 文档。data 是整份 PDF 字节的 ArrayBuffer。
  // password 可选，用于打开加密文档（阅读、属性、书签都会用同一密码）。
  // 成功返回文档句柄（BigInt），失败返回 null。
  open(data: ArrayBuffer, password?: string): bigint | null;

  // 判断该文件是否需要密码才能阅读（打开加密 PDF 时用来弹密码框）。
  needsPassword(data: ArrayBuffer): boolean;

  // 页数（文档句柄无效时返回 0）。
  pageCount(handle: bigint): number;

  // 渲染某一页为直 alpha 的 RGBA8888（行主序）。
  // 成功返回 { width, height, rgba }，失败返回 null。
  // page 为 0 基页码，scale 为「设备像素 / PDF 点」（2.0 约等于 144dpi）。
  renderPage(
    handle: bigint,
    page: number,
    scale: number
  ): { width: number; height: number; rgba: ArrayBuffer } | null;

  // 文档属性（JSON 字符串）：
  // {"title","author","subject","keywords","creator","producer","pdfVersion",
  //  "fileSize":number,"pages":number,"encrypted":bool,
  //  "fonts":[{"name","kind","embedded"}],
  //  "pageSize":[[widthPt,heightPt,rotationDeg],...]}
  // 失败返回空字符串。
  metadata(handle: bigint): string;

  // 书签/大纲（JSON 字符串，前序扁平化）：
  // {"more":bool,"items":[{"title":string,"page":number(0基或-1)},...]}
  // 失败返回空字符串。
  outline(handle: bigint): string;

  // 全文搜索（JSON 字符串）：
  // {"total":number,"pages":[{"page":number,"count":number,"rects":[[x0,y0,x1,y1],...]},...]}
  // rects 单位为 PDF 点、y 向下（view space）。needle 为空或失败返回 {"total":0,"pages":[]}。
  search(
    handle: bigint,
    needle: string,
    caseSensitive: boolean,
    wholeWords: boolean,
    cap: number
  ): string;

  // 释放文档句柄。
  close(handle: bigint): void;

  // ---- 编辑会话（基于纯 Rust 的 cos/organize/annot/forms/edit crate）----------
  // 打开可编辑文档。password 为打开加密 PDF 用的密码（可省略）。
  // 解析失败或密码错误返回 null。
  editOpen(data: ArrayBuffer, password?: string): bigint | null;

  // 释放编辑句柄。
  editClose(handle: bigint): void;

  // 当前状态 JSON：
  // {"pages":number,"dirty":bool,"canUndo":bool,"canRedo":bool,
  //  "encrypted":bool,"title":string,"author":string,"rotations":[number,...]}
  editState(handle: bigint): string;

  // 执行一条编辑命令。cmd 是带 op 字段的 JSON 字符串。
  // 返回 {"ok":bool,"error":string,"state":{...},<命令专属字段>}。
  // 支持的 op：
  //   组织页面: rotate / deletePages / movePages / reversePages / duplicatePages /
  //             insertBlank / extractPages / setInfo / addBookmark / deleteBookmark /
  //             renameBookmark / numberPages
  //   批注:     addNote / addHighlight / addShape / deleteAnnotation /
  //             setAnnotationContents / replyToAnnotation / listAnnotations
  //   表单:     addField / setFieldValue / deleteField / resetForm / listFields
  //   编辑内容: addText / deleteContent / addWatermark / addHeaderFooter / removeMarks
  //   保护:     encrypt / removeEncryption
  editCommand(handle: bigint, commandJson: string): string;

  // 撤销 / 重做，返回与 editCommand 相同的 JSON 结构。
  editUndo(handle: bigint): string;
  editRedo(handle: bigint): string;

  // 导出编辑后的 PDF 字节。full=true 全量重写（加密变更后必须），false 增量保存。
  // 失败返回 null。
  editSave(handle: bigint, full: boolean): ArrayBuffer | null;
}

declare const pdfc: PdfcNative;
export default pdfc;
