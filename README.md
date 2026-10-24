# OUPOS — iPad POS 開源本機版（v5.5）

### 熱感出單版型（v5.6）

- 以店名置中開頭，醒目顯示內用／外帶與 `#YYMMDD####` 訂單編號。
- 兩欄顯示時間、付款方式；整筆備註放大置中，商品名稱及小計左右對齊。
- 商品下方顯示配料數量及商品備註，底部顯示總數量、金額和 OUPOS 字樣。
- 自動配合 58 mm（384 dots）／80 mm（576 dots）熱感紙縮放；離線已儲存訂單重新出單也使用此版型。
- 參考詳細說明：`RECEIPT_LAYOUT.md`。


原生 iPadOS 17+ POS 專案，直接在 iPad 使用，不需建立雲端會員。**沒有 Google、Apple、Email 登入，也沒有 Supabase、雲端商家資料蒐集或 API 連線。**

## 首次啟用

1. 啟動 OUPOS，在畫面輸入**商家名稱**。
2. 進入既有的「建立管理員帳號」畫面，設定帳號及密碼。
3. 完成後進入 POS。往後開啟以本機管理員／員工帳密登入。

不再要求商家類別、電子郵件或第三方身分驗證。商家名稱存放在本機 App 設定（UserDefaults），用於主畫面顯示，不會由 OUPOS 傳送到任何雲端服務。

## 功能

- 本機菜單／商品分類、商品價格與售完管理、配料群組及配料適用商品（支援依分類全選）。配料有三種選擇方式：複選同一配料可加多份、單選同群組擇一、勾選同群組多種但每種最多一次。點餐介面恢復原本的配料卡片：**複選點整張卡片加一份**，已有數量時左上角顯示**減號**、右上角顯示 **×份數**；**單選是粉紅色底、勾選是黃色底**，兩者均沒有減號，點卡片切換選取。價格、購物車、訂單與收據會正確計算及顯示數量。
- 售完商品不能加入購物車，結帳時也會重新檢查，避免商品已售完仍被下單。
- 本機現場點餐、桌號、付款方式、歷史訂單、報表及 JSON 備份／還原。新訂單編號為 `YYMMDD` + 四位隨機數字（如 `2610224827`），當日在同一台 iPad 不重複，舊訂單編號不變。
- 管理員可管理菜單、歷史訂單、設定與員工帳號；員工只可點餐及變更商品售完狀態。
- 使用 Face ID／Touch ID **且不得回退到裝置密碼**的管理員密碼重設，通過後顯示帳號、重設新密碼，不顯示舊密碼。
- iPad 直接透過店內區域網路 TCP 傳送 ESC/POS 收據至熱感印表機（不是雲端 API）。
- 新增商品與配料的數字欄位預設空白；原本的登入動畫、表單樣式保留。

## AI 新增菜單（JSON）

管理員登入後，進入「設定 → 菜單與配料 → AI 新增菜單」：

1. 點「複製 AI 提示詞」。
2. 自行前往 ChatGPT、Claude 或 Gemini，上傳菜單照片、PDF 或文字並貼上提示詞。
3. 取得純 JSON 後存成 `.json`，或直接貼入 OUPOS 文字框。
4. 選擇 JSON、檢查預覽數量，再確認匯入。可以一次新增分類、商品、配料群組與配料的適用商品設定。

JSON 範例：`examples/ai_menu_example.json`。格式和詳細說明見 `AI_MENU_IMPORT.md`。

匯入只會新增，不會覆蓋同分類同名商品或同群組同名配料，也不會改動既有商品售完狀態、訂單、出單機與帳號。匯入前應先用「備份還原」建立備份。JSON 價格必須是非負整數；不應讓 AI 猜測菜單上看不清楚的價格。匯入不會在 App 內連線到任何 AI 伺服器。

## 開啟專案

開啟 `oupos.xcodeproj`，選擇 iPad 或模擬器，設定 Signing Team；Bundle Identifier 預設為 `app.oupos`。專案不需額外下載第三方 Swift Package，亦不需要設定 Apple 登入 Capability 或 Google URL Scheme。

如果之前安裝過 OUPOS，請**不要為了更新專案而刪除 iPad App**；同一個 Bundle Identifier 的更新可保留現有商品、歷史訂單及管理員／員工 Keychain 帳號。由舊雲端版升級時，首次會要求輸入一次商家名稱；這不會清空現有 POS 營業資料。

## 資料

菜單與訂單寫入 App 沙盒的 `Application Support/Oupos/pos-data.json`；商家名稱是本機偏好設定，管理員／員工憑證仍以 Keychain 保存。商家名稱不包含在 POS JSON 備份中。刪除 App 會刪除 App 沙盒資料，因此請定期匯出備份。Keychain 在重裝後可能仍存在。

本版移除的是 **App 中的 Supabase 功能和連線設定**，不會替你刪除過去已建立於 Supabase 服務端的會員／商家資料；如需刪除服務端資料，請另外在 Supabase Dashboard 處理。

## 目錄

- `oupos/Features/Onboarding/LocalMerchantSetupView.swift`：第一次填寫商家名稱的介面。
- `oupos/Services/LocalMerchantStore.swift`：商家名稱本機保存。
- `oupos/Services/LocalAccountService.swift`：本機帳號與 Keychain。
- `oupos/App/POSStore.swift`：本機訂單、權限和生物辨識密碼重設。
- `oupos/Services/LocalPOSDatabase.swift`：菜單與歷史訂單本機儲存。
- `oupos/Services/AIMenuImport.swift`：AI 菜單 JSON 驗證、去重與匯入預覽。
- `oupos/Features/Settings/AIMenuImportView.swift`：複製 AI 提示詞、選擇 JSON 與確認匯入。
- `oupos/Services/NetworkPrinterService.swift`：區域網路出單機。
- `ouposTests/ouposTests.swift`：本機資料、訂單、帳號和商家名稱測試。

授權：MIT，見 `LICENSE`。開源時請自行確認品牌與圖示的使用權。
