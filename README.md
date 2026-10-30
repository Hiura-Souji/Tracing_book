# 生字簿練習器

描紅生字簿產生器。支援田字格、米字格、九宮格、回宮格，注音欄，橫式／直式書寫，各種紙張大小，詞語句子，手寫練習、描圖，以及用筆順 XML 造字。

格雷資訊 grayfree.tw ・ GitHub @Hiura-Souji

## 兩種用法

| | 網頁版 | 桌面版（AutoIt＋AUI WebView2） |
|---|---|---|
| 開啟方式 | 直接用瀏覽器開 `Web\index.html` | 執行 `ShengZiBu.au3`（或編譯後的 exe） |
| 資料存放 | 瀏覽器的 localStorage | 程式資料夾的 `data\` |
| 列印 | 瀏覽器的列印 | 列印、直接存成 PDF |
| 批次 | 合併列印 | 合併列印、合併存成一個 PDF、每份各存一個 PDF |
| 筆順資料 | 內建 4,844 字（需用網址開啟；直接開檔案時改成每字上網抓） | 內建 4,844 字；其他字第一次下載後快取到 `data\strokes` |
| 本機字型 | 每次手動選檔案 | 放進 `fonts\` 資料夾就會出現在字型選單 |

兩種用法共用同一份 `Web\index.html`。

## 資料夾

```
生字簿\
├─ ShengZiBu.au3      主程式（請用 32 位元 AutoIt 執行；AUI 只支援 x86）
├─ AUI.au3            AUI 介面函式庫
├─ ShengZiBu.ico
├─ Web\index.html     介面（網頁版也是這個檔案）
├─ Web\strokes.json   內建筆順：教育部常用國字標準字體 4,844 字（含注音符號）
├─ fonts\             放字型檔（.ttf .otf .woff .woff2 .ttc）
└─ data\              執行時自動建立
   ├─ state.json      目前的設定與內容
   ├─ glyphs.json     匯入或手繪的筆順、自造字
   ├─ projects\       作業清單，一份作業一個 .json
   ├─ strokes\        下載過的筆順快取
   └─ ShengZiBu.ini   上次存檔的資料夾
```

## 建議放進 fonts 的字型

- 教育部標準楷書（edukai）：<https://language.moe.gov.tw/>
- 全字庫正楷體（TW-Kai，含大量罕用字，可解決缺字）：<https://data.gov.tw/dataset/5961>
- 霞鶩文楷 TC：<https://github.com/lxgw/LxgwWenkaiTC>

這些字型的授權不同，請自行確認可否隨程式散布。

## 注音

- 選「注音欄」後會自動標注音。讀音由 pinyin-pro 判斷（會依詞語判斷破音字），再轉成注音，並修正台灣常見的不同讀音（期、危、微、垃圾、星期…）。
- 讀音標錯時，點上方的字，在「注音」欄修改，也可以用畫面上的注音鍵盤輸入。詞語的注音用空白隔開，例如 `ㄎㄨㄞˋ ㄌㄜˋ`。
- 「空白注音欄」適合讓學生自己寫注音。

## 安全設計

- 本機服務只綁定 `127.0.0.1`，並檢查 Host 標頭（防 DNS rebinding）。
- 所有 `/api/` 都要帶啟動時產生的隨機權杖，權杖放在網址 `#` 後面，不會被送出或記錄。
- 只能讀寫 `data\` 裡固定的幾種檔案；作業名稱會過濾不合法的檔名字元。

## 內建筆順資料

`Web\strokes.json` 是把 g0v zh-stroke-data 的全部 XML（`utf8\*.xml`，4,844 字）轉成精簡格式：每個字一組 SVG 外框路徑（相對座標、整數、座標範圍 0～1075）。程式啟動時預設全部載入，所以常用字都有筆順列與筆順示範，不需要再一個一個匯入。

自己匯入的 XML 或手繪造字，會優先於內建資料。

**授權注意**：筆順資料取自教育部「常用國字標準字體筆順學習網」，教育部規定不得用於商業用途；g0v 是依著作權法第 50 條，為非營利教育目的重製。生字簿練習器可以免費提供給學校、家長使用，但請不要拿這份筆順資料做收費產品。

## 資料來源

- 筆順：g0v [zh-stroke-data](https://github.com/g0v/zh-stroke-data)（教育部常用國字標準字體筆順學習網，限非營利教育使用）、[Make Me a Hanzi](https://github.com/skishore/makemeahanzi)（hanzi-writer-data）
- 拼音：[pinyin-pro](https://github.com/zh-lx/pinyin-pro)
- 簡繁轉換：[opencc-js](https://github.com/nk2028/opencc-js)
