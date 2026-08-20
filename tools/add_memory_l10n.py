"""Insert the 3-layer memory localization keys into the four ARB files.

Safe path: read the JSON, mutate the dict, write it back. UTF-8, no BOM.
"""

import json
import os
import sys
from collections import OrderedDict

WS = r"F:\Desktop\kelivo temp"

# English source values. The other three locales get the same key set with
# their own translations. Use empty string when no value yet.
EN = {
    "commonSave": "Save",
    "commonCancel": "Cancel",
    "commonDelete": "Delete",
    "memorySettingsPageTitle": "3-Layer Memory",
    "memorySettingsPageSectionMaster": "Master",
    "memorySettingsPageEnableThreeLayer": "Enable 3-Layer Memory",
    "memorySettingsPageEnableThreeLayerSub": "Combine system prompt memory, cross-window context, and ranked long-term memories.",
    "memorySettingsPageSectionPreset": "Preset",
    "memorySettingsPagePresetHelp": "Pick a preset for a coherent set of values, or tweak the numbers below for a custom configuration.",
    "memorySettingsPageSectionCrossWindow": "Cross-Window",
    "memorySettingsPageEnableCrossWindow": "Share recent chats across windows",
    "memorySettingsPageEnableCrossWindowSub": "Let this assistant see what you talked about in other windows of the same persona.",
    "memorySettingsPageEnableCompression": "Compress older entries",
    "memorySettingsPageEnableCompressionSub": "Periodically summarize old entries to keep the prompt small.",
    "memorySettingsPageCompressionThresholdTitle": "Compression threshold",
    "memorySettingsPageCompressionThresholdSub": "Trigger a compression when the un-compressed tail exceeds this many characters.",
    "memorySettingsPageUnitChars": "chars",
    "memorySettingsPageUnitEntries": "entries",
    "memorySettingsPageTailEntriesTitle": "Un-compressed tail",
    "memorySettingsPageTailEntriesSub": "Always keep this many most-recent entries out of the summary.",
    "memorySettingsPageSectionLongTerm": "Long-Term Memory",
    "memorySettingsPageRecallCountTitle": "Recall count per turn",
    "memorySettingsPageRecallCountSub": "Maximum number of saved memories to inject for one user turn.",
    "memorySettingsPageLongTermMaxCharsTitle": "Recall character budget",
    "memorySettingsPageLongTermMaxCharsSub": "Total characters reserved for the long-term memory block.",
    "memorySettingsPageRecentChatsFallback": "Fall back to recent chats",
    "memorySettingsPageRecentChatsFallbackSub": "When 3-layer is on but cross-window is off, fall back to the recent-chats reference.",
    "memorySettingsPageSectionBank": "Long-Term Bank",
    "memorySettingsPageOpenBank": "Browse long-term bank",
    "memorySettingsPageOpenBankSub": "Search, filter, and delete the rows written by the chat pipeline.",
    "memoryBankPageTitle": "Long-Term Bank",
    "memoryBankPageErrorPrefix": "Failed to load: ",
    "memoryBankPageEmpty": "No memory rows yet. The chat pipeline will fill this in as you talk.",
    "memoryBankPageDeleteTitle": "Delete this row?",
    "memoryBankPageDeleteConfirm": "This row will be removed from the long-term bank. The row in the chat transcript is unaffected.",
    "memoryBankPageStatTotal": "Total",
    "memoryBankPageStatMessages": "Messages",
    "memoryBankPageStatSummaries": "Summaries",
    "memoryBankPageStatManual": "Manual",
    "memoryBankPageSearchHint": "Search content",
    "memoryBankPageTypeAll": "All",
    "memoryBankPageTypeMessage": "Message",
    "memoryBankPageTypePhase": "Phase",
    "memoryBankPageTypeDaily": "Daily",
    "memoryBankPageTypeManual": "Manual",
    "memoryBankPageTypeAuto": "Auto",
    "assistantEditThreeLayerMemoryTitle": "3-Layer Memory Settings",
    "assistantEditThreeLayerMemorySub": "Master switch, presets, cross-window stream, and long-term recall.",
}

# Simplified Chinese (zh) — used by app_zh.arb and app_zh_Hans.arb.
ZH_S = {
    "commonSave": "保存",
    "commonCancel": "取消",
    "commonDelete": "删除",
    "memorySettingsPageTitle": "三层记忆",
    "memorySettingsPageSectionMaster": "总开关",
    "memorySettingsPageEnableThreeLayer": "启用三层记忆",
    "memorySettingsPageEnableThreeLayerSub": "同时使用系统提示词中的固定记忆、跨窗口的近期上下文、以及按相关度排名的长期记忆。",
    "memorySettingsPageSectionPreset": "预设",
    "memorySettingsPagePresetHelp": "选一个预设可一次性应用一组合适的数值，也可以单独调整下方参数。",
    "memorySettingsPageSectionCrossWindow": "跨窗口",
    "memorySettingsPageEnableCrossWindow": "在不同窗口间共享近期对话",
    "memorySettingsPageEnableCrossWindowSub": "让这个助手看到你在同一个助手的其它窗口里聊过的内容。",
    "memorySettingsPageEnableCompression": "自动压缩旧条目",
    "memorySettingsPageEnableCompressionSub": "定期把较早的对话整理成摘要，腾出提示词空间。",
    "memorySettingsPageCompressionThresholdTitle": "压缩触发阈值",
    "memorySettingsPageCompressionThresholdSub": "未压缩的近期条目超过这么多字符时，触发一次压缩。",
    "memorySettingsPageUnitChars": "字",
    "memorySettingsPageUnitEntries": "条",
    "memorySettingsPageTailEntriesTitle": "保留近期条目数",
    "memorySettingsPageTailEntriesSub": "永远保留最近这几条不参与压缩。",
    "memorySettingsPageSectionLongTerm": "长期记忆",
    "memorySettingsPageRecallCountTitle": "每轮注入条数",
    "memorySettingsPageRecallCountSub": "每个用户回合最多注入多少条长期记忆。",
    "memorySettingsPageLongTermMaxCharsTitle": "注入字符预算",
    "memorySettingsPageLongTermMaxCharsSub": "长期记忆块一共占多少字符。",
    "memorySettingsPageRecentChatsFallback": "降级使用近期聊天",
    "memorySettingsPageRecentChatsFallbackSub": "三层记忆开启但跨窗口关闭时，降级到原有的近期聊天引用。",
    "memorySettingsPageSectionBank": "长期记忆库",
    "memorySettingsPageOpenBank": "浏览长期记忆库",
    "memorySettingsPageOpenBankSub": "搜索、筛选、删除聊天流程写入的长期记忆。",
    "memoryBankPageTitle": "长期记忆库",
    "memoryBankPageErrorPrefix": "加载失败：",
    "memoryBankPageEmpty": "还没有任何长期记忆。聊天中讲到的内容会自动写入这里。",
    "memoryBankPageDeleteTitle": "删除这一条？",
    "memoryBankPageDeleteConfirm": "这一条会从长期记忆库中删除。聊天原文不受影响。",
    "memoryBankPageStatTotal": "总数",
    "memoryBankPageStatMessages": "消息",
    "memoryBankPageStatSummaries": "摘要",
    "memoryBankPageStatManual": "手动",
    "memoryBankPageSearchHint": "搜索内容",
    "memoryBankPageTypeAll": "全部",
    "memoryBankPageTypeMessage": "消息",
    "memoryBankPageTypePhase": "阶段",
    "memoryBankPageTypeDaily": "日",
    "memoryBankPageTypeManual": "手动",
    "memoryBankPageTypeAuto": "自动",
    "assistantEditThreeLayerMemoryTitle": "三层记忆设置",
    "assistantEditThreeLayerMemorySub": "总开关、预设、跨窗口和长期记忆参数。",
}

# Traditional Chinese (zh-Hant) — used by app_zh_Hant.arb.
ZH_T = {
    "commonSave": "儲存",
    "commonCancel": "取消",
    "commonDelete": "刪除",
    "memorySettingsPageTitle": "三層記憶",
    "memorySettingsPageSectionMaster": "總開關",
    "memorySettingsPageEnableThreeLayer": "啟用三層記憶",
    "memorySettingsPageEnableThreeLayerSub": "同時使用系統提示詞中的固定記憶、跨視窗的近期上下文、以及按相關度排名的長期記憶。",
    "memorySettingsPageSectionPreset": "預設",
    "memorySettingsPagePresetHelp": "選一個預設可一次套用一組合適的數值，也可以單獨調整下方參數。",
    "memorySettingsPageSectionCrossWindow": "跨視窗",
    "memorySettingsPageEnableCrossWindow": "在不同視窗間共享近期對話",
    "memorySettingsPageEnableCrossWindowSub": "讓這個助手看到你在同一個助手的其他視窗裡聊過的內容。",
    "memorySettingsPageEnableCompression": "自動壓縮舊條目",
    "memorySettingsPageEnableCompressionSub": "定期把較早的對話整理成摘要，騰出提示詞空間。",
    "memorySettingsPageCompressionThresholdTitle": "壓縮觸發門檻",
    "memorySettingsPageCompressionThresholdSub": "未壓縮的近期條目超過這麼多字元時，觸發一次壓縮。",
    "memorySettingsPageUnitChars": "字",
    "memorySettingsPageUnitEntries": "條",
    "memorySettingsPageTailEntriesTitle": "保留近期條目數",
    "memorySettingsPageTailEntriesSub": "永遠保留最近這幾條不參與壓縮。",
    "memorySettingsPageSectionLongTerm": "長期記憶",
    "memorySettingsPageRecallCountTitle": "每輪注入條數",
    "memorySettingsPageRecallCountSub": "每個使用者回合最多注入多少條長期記憶。",
    "memorySettingsPageLongTermMaxCharsTitle": "注入字元預算",
    "memorySettingsPageLongTermMaxCharsSub": "長期記憶塊一共佔多少字元。",
    "memorySettingsPageRecentChatsFallback": "降級使用近期聊天",
    "memorySettingsPageRecentChatsFallbackSub": "三層記憶開啟但跨視窗關閉時，降級到原有的近期聊天引用。",
    "memorySettingsPageSectionBank": "長期記憶庫",
    "memorySettingsPageOpenBank": "瀏覽長期記憶庫",
    "memorySettingsPageOpenBankSub": "搜尋、篩選、刪除聊天流程寫入的長期記憶。",
    "memoryBankPageTitle": "長期記憶庫",
    "memoryBankPageErrorPrefix": "載入失敗：",
    "memoryBankPageEmpty": "還沒有任何長期記憶。聊天中講到的內容會自動寫入這裡。",
    "memoryBankPageDeleteTitle": "刪除這一條？",
    "memoryBankPageDeleteConfirm": "這一條會從長期記憶庫中刪除。聊天原文不受影響。",
    "memoryBankPageStatTotal": "總數",
    "memoryBankPageStatMessages": "訊息",
    "memoryBankPageStatSummaries": "摘要",
    "memoryBankPageStatManual": "手動",
    "memoryBankPageSearchHint": "搜尋內容",
    "memoryBankPageTypeAll": "全部",
    "memoryBankPageTypeMessage": "訊息",
    "memoryBankPageTypePhase": "階段",
    "memoryBankPageTypeDaily": "日",
    "memoryBankPageTypeManual": "手動",
    "memoryBankPageTypeAuto": "自動",
    "assistantEditThreeLayerMemoryTitle": "三層記憶設定",
    "assistantEditThreeLayerMemorySub": "總開關、預設、跨視窗和長期記憶參數。",
}


def patch_arb(path: str, values: dict[str, str]) -> None:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f, object_pairs_hook=OrderedDict)
    # Preserve existing keys verbatim; only add new ones.
    added = 0
    for k, v in values.items():
        if k not in data:
            data[k] = v
            added += 1
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"{os.path.basename(path)}: +{added} keys (total {len(data)})")


def main() -> int:
    patch_arb(os.path.join(WS, "lib/l10n/app_en.arb"), EN)
    patch_arb(os.path.join(WS, "lib/l10n/app_zh.arb"), ZH_S)
    patch_arb(os.path.join(WS, "lib/l10n/app_zh_Hans.arb"), ZH_S)
    patch_arb(os.path.join(WS, "lib/l10n/app_zh_Hant.arb"), ZH_T)
    return 0


if __name__ == "__main__":
    sys.exit(main())
