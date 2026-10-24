# OUPOS AI 菜單 JSON 匯入說明

這不是連接 AI API 的功能。OUPOS 只會在 App 內呈現提示詞，由使用者自行選擇外部 AI 服務並上傳菜單，再匯入 AI 生成的 JSON 檔案或貼上文字。若原始菜單含有個資，使用者應在上傳之前自行刪除。

## 在 iPad 上操作

1. 管理員開啟 **設定 → 菜單與配料 → AI 新增菜單**。
2. 點擊 **複製 AI 提示詞**，在 ChatGPT、Claude、Gemini 等工具貼上提示詞並附上菜單照片或 PDF。
3. 要求 AI 僅回覆 JSON，檢查商品、價格、配料及適用分類。儲存為 `.json` 檔，或複製 JSON 全文。
4. 返回 OUPOS 選擇 JSON 檔案，或貼上 JSON 後點 **檢查貼上的 JSON**。若 AI 複製內容將陣列括號轉成 `\[`、`\]` 或包含 Markdown 的 ```json 程式碼框，App 會自動清理再檢查。
5. 檢查「新增分類／商品／配料群組／配料」預覽數量，再點 **確認新增到菜單**。
6. 如果 AI 讀錯圖片、亂猜價格或分類，請先修改 JSON 或請 AI 重做。**匯入前建議先備份**。

## JSON 範例

見 [`examples/ai_menu_example.json`](examples/ai_menu_example.json)。其中：

- `schemaVersion` 固定為 `1`。
- `categories` 是分類名稱字串陣列，已有的同名分類會重用。
- `products` 每筆要有 `category`、`name`、`price`。分類需對應已有或本次輸入的分類。
- `toppingGroups` 每筆要有 `name`、`maxSelect`（0 代表不限）。
- `toppings` 每筆要有 `group`、`name`、`price`、`selectionType`、`isRequired`、`appliesToCategories`、`appliesToProducts`。
- `selectionType` 僅可為 `single`、`multi`、`checkbox`，`isRequired` 是布林值。
- `appliesToCategories` 指定整個分類的全部商品；`appliesToProducts` 為只套用單一商品的陣列，如 `{"category":"咖啡","name":"拿鐵"}`，兩者可並用。
- 欄位必須齊全。沒有配料時 `toppingGroups` 和 `toppings` 用 `[]`。看不清楚價格時應先釐清，不能猜測。

## 匯入規則

- **追加、不覆蓋**：同名分類、同分類同名商品、同名配料群組、同群組同名配料會重用或略過，不覆蓋既有售價、庫存／售完、配料適用範圍。
- **全部驗證後才寫入**：任何商品分類、配料群組、適用商品無法對應、價格不是有效非負整數等錯誤，都會拒絕本次匯入；不會只寫入一半。
- **保留營業資料**：原有訂單、報表、桌號、付款方式、印表機設定和員工帳號不變。新增資料會存到 iPad 的本機 POS 資料檔。
- **權限**：僅管理員可預覽與真正匯入；員工仍只能點餐及操作售完狀態。
- **與備份分開**：「AI 新增菜單」的 JSON 與「備份還原」的完整 POS JSON 不同，請勿混用。

此功能不連接 Supabase、不要求雲端登入，也不含任何第三方 AI SDK。
