// PdfCraft for HarmonyOS —— UIAbility 入口。
//
// 职责很轻：
//   1. 从「打开方式」被唤起时，把 PDF 的 uri 存进 AppStorage('pendingPdfUri')，
//      让 pages/Index 在 aboutToAppear 里取走并直接渲染（见 Index.ets）。
//   2. 加载主页面 pages/Index。
//
// 没有 RustDesk 那种后台渲染循环 / 会话管理 —— PDF 阅读是纯静态文档，
// 渲染由页面按需触发（pdfc.renderPage 同步调用）。

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3200;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 通过「文件管理器 → 打开方式」打开 PDF 时，uri 在 want.uri 里。
    // 存进 AppStorage 供主页面消费；本条 want 消费后即删，避免二次进入时重复加载。
    const uri: string | undefined = want?.uri;
    if (uri && uri.length > 0) {
      AppStorage.setOrCreate<string>('pendingPdfUri', uri);
      hilog.info(DOMAIN, TAG, 'open-with uri: %{public}s', uri);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'content loaded');
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用已在后台时再次被「打开方式」唤起（单实例复用）：刷新 pendingUri，
    // 页面在 onShown 里可以重新读取。这里同样写入，Index 侧用 aboutToAppear
    // 之外的路径也能感知（当前实现里 aboutToAppear 只跑一次，重复唤起走本页刷新）。
    const uri: string | undefined = want?.uri;
    if (uri && uri.length > 0) {
      AppStorage.setOrCreate<string>('pendingPdfUri', uri);
    }
  }
}
