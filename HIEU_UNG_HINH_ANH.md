# Saltline – Phân tích chi tiết kỹ thuật hình ảnh

Tài liệu này giải thích **vì sao Saltline trông đẹp** và **từng hiệu ứng được làm như thế nào**, dựa trên việc đọc trực tiếp mã nguồn trong `saltline_1.html`.

## 0. Cách đọc tài liệu này

- `saltline_1.html` là bản **đã bundle và minify** (~1,4 MB, 6196 dòng nhưng có nhiều dòng dài hàng chục nghìn ký tự), gồm Three.js r180 và toàn bộ code game. Tên biến trong code đã bị rút gọn (`Mn`, `en`, `Pr`, `jy`…), nên tài liệu đặt tên mô tả cho dễ hiểu và ghi kèm vị trí để tra cứu.
- Số dòng nêu ra là **gần đúng**. Dùng chúng để tìm bằng `grep` hoặc `sed -n 'a,bp'`, đừng coi là cố định.
- Mọi con số (hằng số, uniform, số mẫu…) được **trích từ code**. Chỗ nào là suy luận của mình thì có ghi *(suy luận)*. Mục 19 liệt kê những gì **chưa kiểm chứng**.
- Mình chưa chạy game để đo FPS hay chụp từng pass. Mọi nhận định về "trông như thế nào" là từ đọc code, không phải từ quan sát hình.

### Bản đồ vị trí trong file (gần đúng)

| Phần | Dòng | Ghi chú |
|---|---|---|
| CSS/UI (`game/ui.css`) | ~10–350 | Biển báo cảng + title card phim |
| Three.js (thư viện) | ~391–4080 | Không phải code game |
| Sky shader (`SALTLINE_SKY`) | ~4199–4290 | Bầu trời, mây, mặt trời |
| Soft shadow (PCSS) | ~4290–4340 | Thay `getShadow` của Three.js |
| Shader hậu kỳ | ~4340–4735 | SSAO, volumetric, motion blur, bloom, grade, final |
| Orchestrator hậu kỳ `jy(...)` | ~4736 | Hằng số tinh chỉnh `TUNE`, render target, thứ tự pass |
| Renderer `Hg(...)` | ~4736 | Cấu hình WebGL, ánh sáng, dynamic resolution |
| Texture procedural | ~4740–5285 | 27 loại bề mặt sinh bằng shader |
| Patch vật liệu | ~5290–5445 | Triplanar, ướt, macro variation |
| Mặt đường (ground) | ~5445–5655 | Vũng nước, nứt, vạch kẻ, phản xạ |
| Biển | ~5657–5725 | Sóng, bọt, haze |
| Mưa & splash | ~5728–5815 | Hạt mưa, giọt nhỏ, vành văng |
| Hệ thống particle | ~5817–5935 | Khói, lửa, tracer |
| Preset chất lượng `Pr` | gần dòng 5700+ | test/low/medium/high/ultra |

---

## 1. Bức tranh tổng thể

Game vẽ cảnh 3D bằng **Three.js (WebGL)** vào một **buffer HDR** (số thực nửa độ chính xác, độ sáng có thể vượt 1.0). Sau đó một **chuỗi hậu kỳ tự viết bằng GLSL** biến ảnh HDR thành ảnh cuối, theo cách một camera điện ảnh xử lý ánh sáng.

```
┌─────────────────────────────── MỖI KHUNG HÌNH ───────────────────────────────┐
│ 0. Pre-pass (phản xạ phẳng, v.v.)                                             │
│ 1. Cập nhật shadow map mặt trời (cách 1 khung, trừ preset ultra)              │
│ 2. Vẽ thế giới vào buffer HDR (MSAA 0/2/4)                                    │
│ 3. Vẽ súng/tay (camera thứ hai) với depth range bị nén → không xuyên tường    │
│ 4. Depth → linear depth nửa độ phân giải                                      │
│ 5. SSAO nửa độ phân giải → blur ngang → blur dọc (có nhận biết depth)         │
│ 6. Volumetric light nửa độ phân giải → blur ngang → blur dọc                  │
│ 7. Composite: nhân AO, cộng sương/tia sáng (bilateral upsample)               │
│ 8. Motion blur (chỉ preset high/ultra)                                        │
│ 9. Bloom: 6 mức downsample + 5 mức upsample; anamorphic streak                │
│10. Eye adaptation (đo độ sáng + độ lộ của mặt trời, buffer 1×1)               │
│11. Grade: CA → bloom → dirt → streak → flare → exposure → tone map → màu      │
│12. Final: FXAA → sharpen → grain → dither → ra màn hình                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

Ba ý chính khiến ảnh đẹp:

1. **Ánh sáng đúng vật lý và đặt có chủ đích**: mặt trời thấp, bầu trời có mây, bóng mềm, sương có tia sáng.
2. **Chuỗi hậu kỳ giống camera phim**: tone mapping, bloom, flare, adaptation, grain.
3. **Chi tiết bề mặt dày**: mọi texture đều sinh bằng thuật toán, có rỉ sét, vết sơn bong, ướt mưa, vũng nước.

---

## 2. Dựng cảnh: renderer và định dạng buffer

### 2.1 Cấu hình `WebGLRenderer`

Trích từ hàm renderer (`Hg`):

| Thiết lập | Giá trị | Ý nghĩa |
|---|---|---|
| `antialias` | `false` | Không dùng AA mặc định của canvas; AA đến từ MSAA của render target + FXAA cuối |
| `powerPreference` | `"high-performance"` | Yêu cầu GPU rời nếu có |
| `alpha` / `stencil` | `false` / `false` | Không cần |
| `shadowMap.enabled` | `true`, `autoUpdate = false` | Game **tự quyết định** khi nào cập nhật bóng |
| `autoClear` | `false` | Game tự clear để kiểm soát từng pass |
| Pixel ratio | `min(devicePixelRatio, 2)` | Giới hạn 2× |

### 2.2 Render target

- **HDR scene** (`m`): `HalfFloatType`, có depth texture và **MSAA** theo preset (`samples = quality.msaa` = 0/2/4).
- **LDR** (`ldr`): 8-bit, là đầu ra của pass grade, rồi pass cuối đọc từ đây.
- **Depth nửa độ phân giải**: định dạng `R32F` nếu có `EXT_color_buffer_float`, nếu không thì dùng half-float.
- AO, volumetric: nửa độ phân giải.
- Bloom: 6 mức down, 5 mức up.
- Adaptation: 2 buffer 1×1 ping-pong.
- Lens dirt: 512×288.

### 2.3 Hệ camera: một cho thế giới, một cho súng

- Camera thế giới `a`: near **0.08**, far **900**.
- Camera súng/tay `l`: near **0.01**, far **10**, vẽ ở layer riêng.
- Khi vẽ súng, game gọi **`gl.depthRange(0, 0.05)`**: ép toàn bộ độ sâu của súng vào 5% đầu của dải depth. Hệ quả là súng **không bao giờ cắt vào tường**, và các pass hậu kỳ nhận ra súng nhờ điều kiện `depth < 0.05` (xem hằng `n1 = "0.05"` trong shader) để **bỏ qua** AO/sương trên súng.
- Súng có thêm `environmentIntensity` nhân `viewFill` (mặc định **1.35**) để luôn đủ sáng.

### 2.4 Tone mapping nội bộ của Three bị tắt

Trong đường ống nâng cao, `toneMapping` của Three được đặt về `NoToneMapping` (giá trị 0) và mọi shader hậu kỳ có `toneMapped: false`; việc tone mapping **hoàn toàn do shader grade** thực hiện. Chỉ khi pipeline hậu kỳ lỗi, game rơi về render thẳng với **ACESFilmic**, exposure **0.6**.

### 2.5 Tự kiểm tra và dự phòng

Lúc khởi tạo game vẽ một khối lập phương thử để kiểm tra shader biên dịch được. Nếu shader hậu kỳ hỏng, game **tự tắt pipeline nâng cao** và rơi về forward rendering (`console.error("[render] advanced pipeline disabled...")`). Nếu soft shadow bị driver từ chối, quay về PCF mặc định của Three.

---

## 3. Mặt trời, bầu trời và ánh sáng môi trường

### 3.1 Thông số mặt trời và bầu trời

Trích từ hằng số của game:

```
Mặt trời:   hướng (0.916, 0.225, 0.331) đã chuẩn hóa
            màu   (1.00, 0.72, 0.42)   → cam ấm
            cường độ 9
Bầu trời:   zenith       (0.055, 0.085, 0.130)   → xanh tối
            horizon      (0.95, 0.55, 0.28)      → cam cháy phía mặt trời
            horizonAway  (0.16, 0.22, 0.30)      → xanh xám phía đối diện
            fog          (0.42, 0.47, 0.52)      → màu sương
```

Thành phần `y = 0.225` cho **độ cao mặt trời ≈ 13°** trên đường chân trời. Đây là **mặt trời thấp** (kiểu hoàng hôn/bình minh), nên ánh sáng đi xiên, bóng đổ dài, màu ấm. Code không ghi rõ là bình minh hay hoàng hôn.

### 3.2 Shader bầu trời (`SALTLINE_SKY`)

Bầu trời không dùng texture. Nó được tính trong fragment shader bằng:

1. **Gradient trời quang**: pha giữa màu horizon, dải sáng nhạt phía trên vùng cháy (`midC`) và màu zenith, theo độ cao `h`.
2. **Quầng Mie quanh mặt trời** bằng tổng 4 lũy thừa của `dot(d, sunDir)`:
   ```
   pow(s, 8)*0.14 + pow(s, 64)*0.55 + pow(s, 600)*2.2 + pow(s, 6000)*14
   ```
   Số mũ tăng dần (8 → 6000) tạo vầng sáng rộng, nhạt dần rồi cô đặc thành lõi rất chói.
3. **Tầng mây** chiếu như "mái" phía trên:
   - Tọa độ mây `cuv = d.xz / (h + 0.10)`: phép chiếu phối cảnh làm mây thu nhỏ về chân trời.
   - Gió: `wind = (-0.012, 0.004) * time` làm mây trôi.
   - **Domain warping**: nhiễu `fbm3` làm méo tọa độ trước khi lấy mật độ `fbm5`.
   - **Ridged noise** (`1 - |2n - 1|`) tạo nếp gợn dưới đáy mây, mờ dần theo khoảng cách để chân trời không bị aliasing.
   - Độ phủ `cov = smoothstep(0.31, 0.50, body)`.
   - **Khe hở có chủ ý về phía mặt trời**: mây kết thúc cao hơn ở hướng mặt trời (`edge` phụ thuộc `ts = skyToSun(d)`), và một "lỗ rách" (`hole`) luôn đảm bảo mặt trời không bao giờ nằm sau mây đặc.
   - **Mây mỏng** (`scud`) trôi trong khe, làm mờ nhẹ mặt trời.
4. **Chiếu sáng mây**:
   - Phần lạnh: xám phiến (`slate`) tối hơn ở chỗ mây dày.
   - **Tự đổ bóng bằng gradient mật độ** về phía mặt trời: lấy mật độ tại hai điểm (`dens` và `densS` lệch theo hướng mặt trời) để suy ra độ nổi (`relief`).
   - Phần ấm: ánh sáng cam quét ngang đáy mây, mạnh nhất gần mặt trời và gần mép mây.
   - **Viền cháy** (`rim = cov*(1-cov)*4`) ở chỗ mây mỏng.
   - **Sấm chớp**: `uFlash * pow(dot(d, uFlashDir), 5)` làm sáng mây từ bên trong, hướng chớp được chọn ngẫu nhiên mỗi lần có sấm.
   - **Phối cảnh khí quyển**: mây xa hòa vào màu chân trời (`exp(-h*11)`).
5. **Đĩa mặt trời** độ chói **110** (nhân `veil` nếu bị mây che), và **tắt khi chụp environment map** (`1 - uEnv`) vì lúc đó đèn directional đóng vai mặt trời.
6. **Phía dưới chân trời**: màu sương biển/phản chiếu mặt đất (phần lớn bị địa hình che).
7. Khi chụp environment map, màu bị chặn tối đa **6.0** để PMREM không có điểm sáng "firefly".

### 3.3 Ánh sáng IBL từ bầu trời

- Bầu trời được chụp vào cubemap rồi xử lý bằng **PMREM** thành `scene.environment`, `environmentIntensity = 2`.
- **Probe nội thất**: khi người chơi vào bên trong nhà kho (`interiorBoxes[0]`), game đổi sang một cubemap 128×128 được chụp tại tâm nhà kho (cách sàn `min(2.4 m, 40% chiều cao hộp)`), và giảm cường độ xuống ×(1/2) (hằng `Ky/Jy`). Nhờ vậy trong nhà không bị "phản chiếu bầu trời" sai.
- Vật liệu có `userData.interior` được gán `envMap` riêng.

### 3.4 Đèn trong cảnh

- 1 `DirectionalLight` "sun" (cường độ 9) có đổ bóng.
- Ngoài ra là một **pool 6 `PointLight`** dùng cho chớp nòng súng và hiệu ứng tạm thời: `distance 12`, `decay 2`. Hàm `flash(pos, màu, cường độ=30, tầm=10, ttl=0.06s)` gán đèn rảnh, và cường độ giảm tuyến tính theo thời gian sống. Có thể "mượn" đèn lâu dài (`acquire`) rồi trả (`release`).

---

## 4. Bóng đổ mềm kiểu PCSS

Mặc định Three.js chỉ cho bóng cứng/PCF. Game **thay hàm `getShadow`** trong shader chunk bằng bản của mình (PCSS – Percentage-Closer Soft Shadows). Cách hoạt động:

1. **Receiver-plane depth bias**: dùng `dFdx/dFdy` của tọa độ bóng để suy ra độ dốc depth của bề mặt nhận bóng, rồi trừ đi độ lệch theo từng texel. Giảm mạnh acne mà không gây "peter-panning". Độ dốc bị chặn (`maxSlope = 0.003 / texel`).
2. **Blocker search**: lấy mẫu một đĩa **Vogel** (xoắn ốc góc vàng, `2.39996323` rad) quanh điểm cần tô, tìm độ sâu trung bình của các vật chắn. Số mẫu `searchTaps = 8`.
3. **Penumbra**: độ rộng vùng bóng mờ tỷ lệ với **khoảng cách giữa vật chắn và bề mặt** (`distM * 0.022 * radius`, kẹp trong khoảng `[0.012, 0.60] * radius`). Vật càng xa chỗ đổ bóng thì bóng càng mềm, giống đời thực.
4. **Lọc**: lấy `taps` mẫu Vogel trong bán kính penumbra (**16** ở preset thường, **10** ở `low`).
5. **Xoay ngẫu nhiên theo pixel**: góc xoay đĩa lấy từ **Interleaved Gradient Noise** (`slIGN`) → nhiễu dạng "blue-noise-like", dễ bị mắt bỏ qua hơn banding.
6. **Mờ dần ở rìa map**: `smoothstep(0, 0.02, min(e.x, e.y))` để không thấy đường viền khung bóng.

Thông số khác:

- Kích thước shadow map theo preset: 1024 (test) / 2048 (low, medium) / **4096** (high, ultra).
- `bias = -0.00012`, `normalBias = 0.02`.
- **Cập nhật bóng cách 1 khung** (`(T & 1) === 0`), trừ preset `ultra` hoặc khi chụp ảnh: giảm một nửa chi phí bóng, vì mặt trời đứng yên.
- Khung bóng được dựng sát khu cảnh (các điểm `(-41,-0.2,-33)`, `(37,32,31)`… trong code) để tập trung độ phân giải vào vùng chơi.

---

## 5. SSAO – Ambient Occlusion trong không gian màn hình

Chạy ở **nửa độ phân giải**.

### 5.1 Chuẩn bị depth

Pass `depthhalf` chuyển depth buffer sang **linear depth** `z = near*far / (far - d*(far-near))`, lấy bằng `texelFetch` với ô lưới chẵn (comment trong code: lấy mẫu ở góc texel sẽ chọn hàng không đoán trước và gây sọc AO trên sàn xiên).

### 5.2 Pass AO

1. Dựng lại vị trí view-space `P` từ `z` và `tanHalf` FOV.
2. **Pháp tuyến từ depth**: lấy chênh lệch với hàng xóm trái/phải và trên/dưới, chọn bên **gần hơn về depth** (`abs(zl - z0) < abs(zr - z0)`) để không lẫn qua mép vật thể, rồi `cross(dx, dy)`.
3. Bán kính: `R = radius * (0.6 + 0.4 * clamp(z0 / 12, 0, 1))` với `radius = 0.9 m`, nhỏ hơn khi ở gần camera. Bán kính trên màn hình `rUv` bị kẹp.
4. Vòng lặp `AO_TAPS` mẫu (**12** mặc định, **8** cho `low`/`test`, **16** cho `ultra`) theo đường xoắn ốc 3 vòng, **xoay ngẫu nhiên theo pixel** bằng IGN.
5. Mỗi mẫu đóng góp:
   ```
   f = max(R² - |v|², 0)
   sum += f³ * max((dot(v, n) - (0.015 + 0.004*z0)) / (|v|² + 0.004), 0)
   ```
   Trọng số `f³` làm các mẫu gần có ảnh hưởng mạnh hơn nhiều; phần trừ trong tử số là bias chống tự che.
6. `ao = max(0, 1 - intensity * sum * 5 / (R⁶ * taps))` với `intensity = 1.6`.
7. **Fade theo khoảng cách**: `mix(ao, 1, smoothstep(70, 140, z0))` – AO biến mất ở xa.

### 5.3 Blur có nhận biết depth

Hai pass 7-tap (ngang rồi dọc). Trọng số mỗi mẫu = `(1 - 0.22*|i|)` × `max(0, 1 - |z - zc| / (BLUR_TOL*zc + 0.02))`. `BLUR_TOL = 0.04` cho AO: blur **không bắc qua mép vật thể**, nên không có quầng sáng quanh vật.

### 5.4 Áp dụng (trong pass composite)

- **Bilateral upsample** từ nửa độ phân giải: lấy 4 texel gần nhất, trọng số = trọng số bilinear × `1 / (0.015 + |zh - zc| / zc)` → upsample theo độ sâu, giữ mép sắc.
- AO **chỉ nên che ánh sáng môi trường**, nên bị giảm ở pixel đã sáng: `a = mix(1, ao, strength * (1 - 0.8*lit))` với `strength = 0.95`, `lit = smoothstep(0.16, 0.85, luma * exposure)`. Nhờ vậy bề mặt dưới nắng không bị "bẩn" quầng AO.
- Tông màu: AO hơi **lạnh** (`mix(vec3(a), 1, (0, 0.03, 0.07))`) → vùng tối ngả xanh nhẹ.
- Không áp AO lên bầu trời (`d < 0.99999`) hay lên súng (`d >= 0.05`).

---

## 6. Volumetric light – tia sáng xuyên sương

Đây là hiệu ứng tạo ra cảm giác "không khí có thể nhìn thấy".

Chạy ở **nửa độ phân giải**, **ray-march** từ camera tới từng pixel, mỗi bước hỏi shadow map xem điểm đó có thấy mặt trời không.

### 6.1 Thuật toán

1. Tia `rd` đi từ camera qua pixel; độ dài tối đa `maxD = min(dist, uMaxDist)` với `uMaxDist = 170 m` (bầu trời chỉ dùng 55% khoảng đó).
2. **Phân bố bước không đều**: `t1 = maxD * f * (0.35 + 0.65*f)` với `f = (i+1)/N` → bước **dày hơn gần mắt**.
3. **Jitter** điểm lấy mẫu trong mỗi bước bằng IGN → mất banding, thay bằng nhiễu mịn mà bước blur sau làm sạch.
4. Tại mỗi điểm `p`:
   - `sh = sunVis(p)`: hỏi shadow map (đọc RGBA đóng gói độ sâu).
   - **Mật độ sương theo độ cao**: `shape(h) = 0.30 + 0.70 * exp(-h/5.5)` → sương dày sát đất, loãng dần lên cao với thang 5.5 m.
   - `extinction = sigma * shape(p.y)` với `sigma = 0.0034`.
   - **Nhà kho đầy bụi**: bên trong hộp `uBoxMin/uBoxMax`, `extinction *= 1 + uBoxDust * inside` với `volInteriorDust = 6` → ánh nắng xuyên qua cửa/khe/lỗ mái hiện rõ thành những cột sáng.
5. **Hàm pha hai thùy**:
   ```
   ph = hg(mu, 0.78)*0.55 + hg(mu, 0.25)*0.45   (tối đa 1.15)
   ```
   `hg` là Henyey–Greenstein. Thùy hẹp (g = 0.78) tạo quầng vàng khi nhìn về phía mặt trời; thùy rộng (g = 0.25) giữ các tia nhìn nghiêng vẫn thấy được. (Comment trong code nói đúng ý này.)
6. **Hướng nghệ thuật** (`nearW`): trọng số mạnh gần mắt (×2.3) và nhẹ ở xa (×0.55) → tia sáng **giữa các chồng container** rõ nét, còn xa chỉ là một màn sương mờ.
7. Tích lũy theo công thức quang học: `acc += T * src * (1 - Ti); T *= Ti`.
8. **Phần xa hơn `uMaxDist`** (tàu, cần cẩu, đường chân trời) không march nữa mà dùng **công thức giải tích** tính độ mờ `exp(-tau)` và hòa vào `horizonColor(rd)`.
9. Ánh sáng môi trường thêm vào sương: `uAmb = fog * volAmbient (0.2) * (1 + 1.5*thunder)` → **sấm chớp làm sương sáng lên**.

### 6.2 Số bước theo preset

| Preset | Số bước volumetric |
|---|---|
| test | 10 |
| low | 12 |
| medium | 16 |
| high | 24 |
| ultra | 40 |

*(Lưu ý: hàm `applyQuality` còn dùng một mức tối thiểu 6 bước.)*

### 6.3 Blur và hợp nhất

Cũng blur 2 chiều có nhận biết depth, nhưng dung sai lớn hơn AO (`BLUR_TOL = 0.30`) vì sương mềm hơn. Kết quả hợp vào ảnh bằng `col = col * vol.a + vol.rgb` (độ truyền qua `a` nhân màu cảnh, cộng ánh sáng tán xạ `rgb`).

---

## 7. Motion blur

- Chỉ bật ở preset **high** và **ultra** (hoặc ép bằng `?mb=1`).
- Là **motion blur do camera di chuyển**: dựng lại vị trí thế giới từ depth (`uInvViewProj`), chiếu bằng **ma trận view-projection của khung hình trước** (`uPrevViewProj`) để suy ra vận tốc pixel.
- `uShutter = min(0.5, 1/190 / dt)` → mô phỏng tốc độ màn trập **1/190 giây**, nhưng không vượt 50% độ dài khung hình.
- Độ dài vệt bị chặn **0.018** (UV). Bỏ qua nếu vệt < 0.75 pixel.
- **9 mẫu** dọc theo vệt, jitter bằng IGN. Mẫu rơi vào pixel súng (`depth < 0.05`) có trọng số 0 → súng **không bị nhòe** theo camera.

---

## 8. Bloom và các hiệu ứng ống kính

### 8.1 Bloom kiểu dual-filter (phong cách Call of Duty)

- **6 mức downsample**, **5 mức upsample**.
- Downsample dùng **bộ lọc 13 tap** (lưới 3×3 ở bước 2 pixel + 4 điểm nội suy).
- Ở **mức đầu tiên** dùng **trung bình Karis từng phần**: mỗi nhóm 4 pixel được cân theo `1 / (1 + luma*0.08)`, để **điểm sáng cực mạnh (như mặt trời) không gây nhấp nháy/firefly**. Mỗi mẫu cũng bị chặn ≤ 400.
- Upsample dùng **bộ lọc tent 3×3** (trọng số 4-2-1) và trộn với mức cao hơn bằng `uMix = bloomMix = 0.62`.
- Kết quả ghép vào ảnh bằng **trộn bảo toàn năng lượng**: `col = mix(col, bloom, 0.065)`.

### 8.2 Lens dirt – vết bẩn ống kính

Một texture 512×288 **sinh ngay lúc khởi động** bằng shader: ~70 đĩa mờ kích cỡ ngẫu nhiên (hash theo chỉ số) + vết nhòe `fbm5 × fbm3` + vệt sọc dọc, tối hơn ở giữa và sáng ở rìa. Áp dụng bằng `col += bloom * dirt * 0.1` – **chỉ hiện ở chỗ bloom sáng**, như bụi trên ống kính thật khi nhìn vào nguồn sáng.

### 8.3 Anamorphic streak – vệt sáng ngang

- Lấy mức bloom thứ 3 (`down[2]`).
- Hai pass Gaussian ngang 15 tap, khoảng cách tap **1.5 texel** rồi **5 texel**.
- Pass đầu có **ngưỡng** `streakThreshold = 2.2` (chia cho exposure hiện tại) → chỉ nguồn rất sáng mới sinh vệt.
- Tô màu **xanh lam** `(0.45, 0.62, 1.0)` với cường độ `0.03` (giống ống kính anamorphic thật).

### 8.4 Lens flare gắn với mặt trời

Tính trong pass grade, chỉ khi mặt trời ở trước camera và **không bị che**:

- **Veiling glare**: `0.020 / (r²*9 + 0.010) + 0.10*exp(-3.2r)`.
- **Gai nhiễu xạ**: `pow(|cos(3θ + 0.4)|, 24) + 0.6*pow(|cos(4θ - 1.1)|, 40)` – sao nhiều cánh.
- **Bóng ma** dọc trục mặt trời – tâm ảnh với màu và kích thước khác nhau (xanh lục, cam, xanh dương, vàng).
- **Vòng halo** ở phía đối diện mặt trời.
- Cường độ `flare = 0.16`, và còn nhân `(1 + dirt*1.5)` → bụi ống kính làm flare rõ hơn.

**Kiểm tra che khuất (occlusion test)** nằm trong pass adaptation: lấy **12 mẫu depth** theo xoắn ốc bán kính 0.011 UV quanh vị trí mặt trời trên màn hình; mẫu nào "thấy trời" (depth = 1) hoặc ngoài màn hình thì tính là thấy. Giá trị được làm mượt với hằng số thời gian **0.12 s** → flare **mờ dần** khi mặt trời bị che, không tắt đột ngột.

### 8.5 Quang sai màu (Chromatic Aberration)

Lệch kênh R và B ngược chiều theo bán kính: `off = c * r² * (ca + damage*0.006)` với `ca = 0.0013`. Rất nhẹ ở trạng thái bình thường; **tăng khi bị thương**.

---

## 9. Eye adaptation – mắt thích nghi ánh sáng

Pass `adapt` ghi vào buffer **1×1** (2 buffer ping-pong):
- Kênh **R**: độ sáng trung bình (đo bằng **trung bình log**).
- Kênh **G**: độ lộ (visibility) của mặt trời.

Cách đo:

1. Lấy lưới **7×5** mẫu từ mức bloom nhỏ nhất (`down[5]`).
2. **Metering ưu tiên tâm**: trọng số `w = 1 - 0.75*smoothstep(0.1, 0.55, |uv - 0.5|)`.
3. Trung bình log: `exp(Σ w·ln(luma) / Σ w)`, kẹp trong `[0.002, 40]`. Trung bình log phản ứng giống mắt người hơn trung bình thường.
4. Làm mượt theo thời gian: `a = mix(prev, avg, rate)`, với `rate = 1 - exp(-dt/adaptTau)`, `adaptTau = 1.5 s`. Khung đầu tiên dùng tốc độ 1 (tức đặt ngay).
5. Có bảo vệ NaN/vô cực.

Áp dụng ở mọi pass cần biết exposure:

```
exposure = uExposure * mix(1, clamp(pow(key / avg, 0.85), minE, maxE), auto)
key = 0.12, minE = 0.6, maxE = 2.0
```

Hệ quả: bước từ chỗ tối ra ngoài nắng thì ảnh chói rồi dịu dần trong khoảng vài giây; vào chỗ tối thì mắt sáng lên. Số mũ **0.85** (thay vì 1) nghĩa là adaptation **không bù hết**, vẫn giữ cảm giác sáng/tối thật.

---

## 10. Tone mapping, color grading và hoàn thiện

Thứ tự chính xác trong pass `grade` (đọc từ code):

1. **Chromatic aberration** khi lấy mẫu cảnh.
2. **Mờ rìa khi ngắm (ADS)**: trộn với mức bloom nhỏ (`tBlur = down[1]`) ở vùng ngoại vi, tối đa 0.75.
3. **Bloom** (energy-conserving mix), cộng **dirt** và **streak**.
4. **Lens flare** (đã nhân độ lộ mặt trời).
5. **Exposure** (thủ công × thích nghi tự động).
6. **Chớp họng súng**: cộng `(1, 0.97, 0.9) * uFlash * 2.5`.
7. **Filmic tone mapping**: `mix(ACES, AgX, 0.25)`.
   - **ACES** (Hill fit, đầu vào nhân 1.3) → tương phản mạnh, màu cam rực.
   - **AgX** (khớp Filament/Blender, thêm look "punchy" với `LOOK_POWER = 1.18`, `LOOK_SAT = 1.22`) → vùng sáng chuyển mượt về trắng thay vì cháy.
   - Pha 25% AgX để lấy ưu điểm của cả hai.
8. **Split-tone**: nhân bóng đổ với `(0.80, 1.01, 1.13)` (ngả teal), vùng sáng với `(1.07, 1.0, 0.90)` (ngả ấm), chuyển theo `smoothstep(0.03, 0.55, luma)`. Đây là phối màu "**teal & orange**" quen thuộc của điện ảnh.
9. **Đường cong chữ S nhẹ**: `mix(col, col²(3 - 2col), 0.22)` → tăng tương phản vừa phải.
10. **Nâng đen**: `col * 0.988 + (0.006, 0.0085, 0.011)` → đen không bị đặc, hơi ngả teal.
11. **Độ bão hòa động**: `sat = saturation * (1 - 0.65*lowHealth) * (1 - 0.5*damage)`.
12. **Vignette**: `0.3 + lowHealth*0.55 + ads*0.22`, với đường cong `smoothstep` bậc 3 theo bán kính.
13. **Viền đỏ sát thương**: khi `damage > 0` hoặc `lowHealth > 0`, trộn màu đỏ sẫm `(0.55, 0.02, 0.01)` ở rìa; khi máu thấp thì **nhấp nháy theo nhịp** `sin(time*5)`.
14. **Fade** (`uFade`) cho chuyển cảnh.
15. **Chuyển sang sRGB** bằng công thức chuẩn.

### Pass cuối (`final`)

1. **FXAA** tự viết: dùng **luma lưu ở kênh alpha** của ảnh grade (tiết kiệm một lần tính), ngưỡng `max(0.0312, lMax*0.10)`, chỉ chạy ở pixel có tương phản đủ lớn.
2. **Sharpen (unsharp mask)** `0.3`, **giảm ở cạnh mạnh** (`1 - smoothstep(0.04, 0.22, contrast)`) vì cạnh đó thuộc về FXAA.
3. **Film grain** động: `hash` hai lần để có phân phối tam giác, hạt thay đổi theo thời gian, **trọng số theo độ sáng** (mạnh ở vùng tối `×1`, yếu ở vùng sáng `×0.30`, gần như không có ở đen tuyệt đối). `grain = 0.02`.
4. **Dither** `±1/255` bằng hai hash → **chống banding** trong gradient bầu trời.

---

## 11. Vật liệu và texture procedural

### 11.1 27 loại bề mặt sinh bằng shader

Danh sách (khóa trong `Tn`):

`asphalt, concrete, brick, epoxy, paint, hazard, hull, galv, metal, brushed, rust, diamond, corrugated, chainlink, gunmetal, polymer, carbon, fabric, armor, wood, plastic, tarp, cardboard, rope, tire, glass, water`

Mỗi loại là một hàm `surf(uv)` và gọi `emit(...)` để ghi **3 đầu ra cùng lúc (MRT)**:

| Đầu ra | Nội dung |
|---|---|
| `o0` | Albedo (lưu dạng `sqrt`) + alpha |
| `o1` | ORM: `r = occlusion`, `g = roughness` (kẹp ≥ 0.03), `b = metalness` |
| `o2` | Height **16 bit** đóng gói vào 2 kênh (`floor` và phần lẻ) |

Một pass riêng (`i3`) tính **normal map** từ height bằng đạo hàm 8 láng giềng (trọng số 0.5 trục + 0.25 chéo) với hệ số `uK`; một pass khác (`s3`) bình phương albedo trở lại. Albedo lưu `sqrt` *(suy luận: để mip/lọc giữ độ chính xác ở vùng tối)*.

Kích thước texture theo preset: 256 / 512 / 1024 / 1024 / 2048 (test/low/medium/high/ultra) (trường `quality.tex`). Có chỗ trong code kẹp kích thước này ở **1024** và bật **anisotropic filtering tới 8×** nếu GPU hỗ trợ. Mình chưa lần ra đầy đủ chỗ nào dùng kích thước nào.

### 11.2 Bộ dụng cụ nhiễu

| Hàm | Công dụng |
|---|---|
| `pcg3` / `h3` | Hash số nguyên PCG 3 chiều, **tuần hoàn** (`mod(c, per)`) để texture lặp liền mạch |
| `gn` | Gradient noise (Perlin) với đường cong nội suy bậc 5 `6t⁵ - 15t⁴ + 10t³` |
| `fbm` | Tổng nhiều octave `gn`, chuẩn hóa về ~[0,1] (`v/t*1.8 + 0.5`) |
| `vor` | Voronoi: trả `F1`, `F2` và hai số ngẫu nhiên theo ô |
| `scr` | **Vết xước thẳng** ngẫu nhiên: hướng, độ rộng, độ dài, mật độ |
| `rustMask` | Mặt nạ **rỉ sét** hạt thô: hai tầng `fbm` ở tần số chênh 14× |

### 11.3 Mô hình hư hại sơn `paintDmg`

Dùng chung cho nhiều loại sơn/kim loại, ra ba đại lượng:

- **chip**: vảy sơn bong (hai lớp Voronoi kéo dọc `20×11` và `64×40`, thêm mảng mòn `c3` từ `fbm`, và vết xước `s1`, `s2`).
- **stain**: quầng oxit mỏng quanh chỗ bong.
- **run**: **vệt rỉ chảy xuống dưới** chỗ hư hại – lặp 4 lần dịch `v` theo `0.034` để mô phỏng nước mưa kéo rỉ xuống, nhân với `fbm(uv, (120,1))` tạo sọc dọc.
- Các hư hại **tập trung thành cụm** (`zone = smoothstep(0.58, 0.82, fbm)`), phần lớn tấm vẫn sạch → trông tự nhiên hơn là hỏng đều.

### 11.4 Patch lên shader chuẩn của Three.js

Game **chèn code vào các shader chunk** của `MeshStandardMaterial` (`map_fragment`, `roughnessmap_fragment`, `metalnessmap_fragment`, `normal_fragment_maps`, `aomap_fragment`) bằng `String.replace`. Các tính năng được thêm:

**a) Triplanar mapping** (`SL_TRIPLANAR`)
- Chiếu texture theo 3 trục `zy`, `xz`, `xy`, trộn theo `|n|⁶` (trọng số chuẩn hóa).
- Pháp tuyến cũng được trộn kiểu "whiteout/UDN", rồi biến đổi về view-space bằng hai trục `vSlAx`, `vSlAy` (có tính đến skinning và instancing).
- Dùng cho vật thể lớn để texture **không bị kéo giãn**.

**b) Biến thiên vĩ mô (macro variation)**
- Nhiễu 3D hai tần số (`slN3`) theo vị trí thế giới nhân vào albedo: `1 + macro.x * (n - 0.5) * 2`.
- **Bẩn/ố** (`slGr`): nơi nhiễu cao và occlusion thấp thì tối hơn tới 35%.
- Mục đích: các tấm lặp lại **không lộ ra là lặp**.

**c) Độ ướt do mưa**
- Mặt **hướng lên** ướt nhất, mặt **dọc** ướt dạng sọc (`slStreak`: tích hai nhiễu 3D kéo dọc), mặt **hướng xuống** không ướt (`slExpo`).
- **Dải ẩm ở chân**: chỗ vật thể tiếp đất (`y < 0.5 m`) có vệt bắn nước.
- Ướt → **albedo tối đi và bão hòa hơn** (`mix(lum, color, 1 + 0.5*wet*...)` rồi `*= 1 - wet*...`), **roughness giảm** (`* uSlWetP.y`).
- **Hạt nước** (`slBead`): nhiễu 3D tần số 170 và 410, đặt roughness về **0.05** → những chấm bóng nhỏ; **chỉ hiện khi nhìn gần** (`1 - length(fwidth(pos))*120`).
- Normal map **giảm 45% trên mặt ướt hướng lên** (nước lấp đầy các khe nhỏ).

**d) Chống nhấp nháy specular** (kiểu Toksvig)
`roughness = sqrt(r² + (1 - |n_map|) * 0.6)`; độ dài vector normal map < 1 (do lọc mip) được cộng vào roughness. Roughness bị kẹp ≥ **0.045**.

**e) Lưới thép (`SL_ACUT`) bền theo khoảng cách**
Alpha-test chạy theo **mip LOD**: dây giữ ~1 pixel khi xa, rồi **tan thành màn dither ~1/3 độ phủ** khi các ô thoi nhỏ hơn pixel; các mảnh còn sống bị làm tối (×0.45) để dây dưới nắng không thành "tấm trắng".

**f) Chế độ tint (`SL_TINT` 0–3)**: bốn cách pha màu vật liệu với albedo texture (cộng, trộn theo độ chói, nhân, hoặc không tint) để một texture dùng cho nhiều màu sơn.

---

## 12. Mặt đất (yard) và nền cảng

Mặt đường là một shader riêng, không dùng texture đơn giản:

- **Tấm bê tông 6 m** với khe giãn nở được **trám nhựa đường**.
- **Vết nứt**, một số được trám nhựa.
- Sỏi/cốt liệu sáng (`smoothstep(0.58, 0.78, ...)`), **làn bị xe cán bóng**, **vết dầu** (`alb *= 1 - 0.62*oil`).
- **Vạch sơn** (mòn, bong) và **vết cao su lốp** lấy từ các *data map* (`uMarks`, `uMask`).
- Khi lấy mẫu data map ở gần: dùng **B-spline bicubic 4 tap** (`gBicubic`) – comment: "không bao giờ thấy ô vuông texel của data map, dù camera ở gần đến đâu". Hạt bong tróc được tạo bằng nhiễu **thế giới tới dưới 1 cm**, không dựa vào texel nào.
- **Vũng nước**: tính từ một mặt nạ chiều cao quy mô lớn; nước đọng ở chỗ thấp.
- **Gợn mưa**: một lớp thưa các vòng tròn mở rộng; mỗi ô có một giọt mới mỗi chu kỳ, vị trí/kích thước/cường độ ngẫu nhiên, **ngọn sóng mảnh mờ dần khi nở**. Trả về độ dốc (xz) cộng vào pháp tuyến.
- **Phản xạ phẳng** (planar reflection, `uRefl`, `uReflMatrix`, `uReflLod`) tắt/bật theo preset (`planar`: 0 ở low, 0.5 ở test/medium/high, 1 ở ultra). Phản xạ được làm mờ theo độ nhám (`uReflLod`).
- Specular trực tiếp bị **kẹp ≤ 40** (`min(directSpecular, 40)`) để tránh điểm sáng cháy trên mặt ướt.

---

## 13. Biển

### 13.1 Hình học

Lưới biển rộng đến **880 m** với bước lưới **tăng dần theo khoảng cách** (hàm `gv`: bước đầu 0.75 m, nhân 1.075 mỗi bước, tối đa 120 m). Gần camera lưới dày, xa lưới thưa → không tốn đỉnh cho vùng xa.

### 13.2 Sóng

- **7 sóng định hướng** (bảng `Db`: hướng, số sóng, biên độ...). Biên độ giảm dần từ ~0.02 xuống ~0.0035 khi số sóng nhỏ đi.
- Tổng hợp thành **độ dốc (slope)** theo công thức `a·k·cos(k·(d·xz) - ω·t)`, rồi chuyển thành pháp tuyến. Có **hai nhóm**: `slopeA` cho khoảng cách xa, `slopeB` có chi tiết cho gần (`nearB = 1 - smoothstep(25, 110, dist)`).
- **3 lớp detail normal map** cuộn ở tốc độ khác nhau (tần số 0.113, 0.031 và 0.39) thêm gợn nhỏ.
- **Swell** dài: `sin(dot(xz, (-0.118, 0.05)) - t*0.55 + noise*5)`.
- **Vệt gió (cat's paw)**: `gust = smoothstep(0.38, 0.62, ...)`, những mảng nước gợn → tối hơn, nhám hơn; xen kẽ với vùng phẳng như gương.

### 13.3 Bọt và váng

- Cạnh bến (x = 30) và quanh thân tàu neo (hộp ở `(41, -34.5)`, kích thước 4 × 21.5): khoảng cách có dấu `de` tới các mép đó.
- `foam` = dải theo `de` nhân với nhiễu ngưỡng; `scum` (váng) rộng 5 m.
- Bọt: albedo `(0.3, 0.32, 0.3)`, roughness 0.65, và **làm phẳng độ dốc 60%**.

### 13.4 Màu và độ sáng

- Albedo nước **rất tối** `(0.0045, 0.013, 0.017)`. Vẻ đẹp của biển đến từ **phản xạ bầu trời (IBL) và mặt trời**, không phải từ màu bản thân.
- Roughness: `0.1 → 0.32` tăng theo khoảng cách (từ 12 m đến 380 m), nhân theo gió.
- `gSpark` điều chế độ lấp lánh theo swell và gió.
- **Haze**: từ 220 m đến 860 m, trộn màu sương (màu thay đổi theo hướng mặt trời) tới 80%.

---

## 14. Mưa, giọt nước và particle

### 14.1 Mưa

- Hạt mưa là **quad có vận tốc kéo giãn**, `uVel`, `uBox` quanh người chơi; **mật độ cao hơn gần người chơi** (`rr *= 0.35 + 1.3*|rr|`).
- **Mái nhà kho**: mưa không rơi xuyên mái. Có tối đa **8 lỗ mái** (`uSky[8]`) cho mưa rơi vào trong; hàm `wSky(p)` kiểm tra điểm có nằm dưới lỗ không.
- **Giọt nhỏ giọt ở mái hiên** (`aSeed.w < 0`): rơi tự do từ cao **7 m**.
- **Splash**: mỗi giọt chạm đất tạo một "vương miện" – cung viền mở rộng cộng vài giọt văng ra.
- Mật độ mưa theo preset (`rain`): 0.4 / 0.5 / 0.8 / 1 / 1. Số giọt mưa = `9000 × rain` (tối thiểu hệ số 0.15) và số vụ splash = `900 × rain`.
- **Sấm** là một sự kiện phát ngẫu nhiên với cường độ `0.3 + 0.7·random`; hệ thống bầu trời nhận sự kiện này để chớp mây (mục 3.2) và hệ sương cũng sáng lên (mục 6.1).

### 14.2 Hệ thống particle chung (khói, lửa, bụi, tracer)

Một hệ **instanced billboard** dùng atlas flipbook. Thuộc tính mỗi hạt: vị trí và kích thước (`aPos`), trục kéo dài/pháp tuyến (`aAxis`), màu HDR (`aCol`), và `aMisc` (khung hình, chế độ, tuổi, độ lộ nắng).

Ba chế độ: **billboard**, **kéo giãn theo vận tốc**, **dán lên bề mặt**.

Kỹ thuật đáng chú ý:

- **Chiếu sáng hạt**: dựng pháp tuyến hình cầu giả (`sqrt(1 - r²)*0.9 + 0.05`) rồi cộng pháp tuyến "billow" lấy từ kênh `rg` của flipbook (hạt **có normal map**, nên khói trông có khối).
- **Tán xạ xuôi**: `pow(dot(-V, sunDir), 5)` → khi nhìn **ngược về phía mặt trời**, mép khói mỏng sáng lên (hiệu ứng xuyên sáng).
- **Soft particles**: `softFade()` đọc depth để mờ dần ở chỗ hạt cắt vào hình học, và mờ sát ống kính (`smoothstep(0.2, 0.9, -viewZ)`).
- **Xói mòn alpha theo tuổi**: `smoothstep(er, ..., t.a)` với `er = age*0.45` → khói **tan thành sợi** khi già.
- **Lửa phát sáng**: những hạt có `aMisc.w ≥ 1.5` là lửa tự phát sáng; lửa dùng **alpha blend (không additive)** để lõi đậm, vỏ cam mờ, và khói phía trước còn che được lửa.
- **Tracer** (vệt đạn) cộng dồn additive nhưng **giới hạn bề rộng trên màn hình** (`dist * uPx * aMisc.w`) để vệt gần ống kính không thành tấm to.
- Kết quả **nhân sẵn alpha (premultiplied)** ở cuối shader.

### 14.3 Các hiệu ứng nhỏ khác

- **Hải âu**: vị trí tính hoàn toàn trong **vertex shader**: quỹ đạo tròn quanh tâm với biên độ nhấp nhô, góc đập cánh `sin(t*freq + phase)` trộn với **lượn** (`glide` thay đổi theo thời gian), cánh thu lại theo độ đập.
- **Đèn nhấp nháy** (`vBlink`): vật liệu đèn có chu kỳ sáng/tối `(chu kỳ, pha, độ rộng xung)` làm nhân với màu diffuse, mượt bằng `smoothstep`.
- **Kính ngắm** của súng: shader riêng với `uTilt` (nghiêng kính vài độ cho giống ngoài đời), nhận ánh sáng `uSun`, `uZen`, `uHor` từ bầu trời.

---

## 15. Hiệu ứng gắn với gameplay

| Biến | Tác dụng trong shader |
|---|---|
| `lowHealth` | Giảm bão hòa tới 65%; viền đỏ nhấp nháy `sin(5t)`; vignette +0.55 |
| `damage` | Giảm bão hòa 50%; viền đỏ giật; quang sai màu `+0.006` |
| `ads` (ngắm) | Làm mờ ngoại vi tới 75% bằng bloom mức thấp; vignette +0.22, thu hẹp |
| `flash` | Chớp trắng ấm toàn màn hình khi bắn |
| `fade` | Màn đen chuyển cảnh |
| `thunder` | Chớp mây từ bên trong, sương sáng lên ×(1+1.5·thunder) |
| `saturation` | Chỉnh bão hòa theo kịch bản |

Cách làm này cho phép **truyền thông tin trạng thái bằng hình ảnh** thay vì HUD, và làm cảm xúc rõ hơn.

---

## 16. Hiệu năng và khả năng tự thích nghi

### 16.1 Preset chất lượng (`Pr`)

| Preset | scale | MSAA | Shadow | Tex | Vol steps | AO | Planar | Motion blur | Rain |
|---|---|---|---|---|---|---|---|---|---|
| test | 1 | 0 | 1024 | 256 | 10 | ✔ | 0.5 | ✘ | 0.4 |
| low | 0.7 | 0 | 2048 | 512 | 12 | ✘ | 0 | ✘ | 0.5 |
| medium | 0.85 | 2 | 2048 | 1024 | 16 | ✔ | 0.5 | ✘ | 0.8 |
| high | 1 | 4 | 4096 | 1024 | 24 | ✔ | 0.5 | ✔ | 1 |
| ultra | 1 | 4 | 4096 | 2048 | 40 | ✔ | 1 | ✔ | 1 |

Mặc định chọn tự động: thiết bị **di động** → `low`; GPU phần mềm hoặc **Mali / Adreno / PowerVR / Intel (không phải Arc)** → `medium`; còn lại → `high`.

### 16.2 Ngân sách pixel

Số pixel render nội bộ bị kẹp theo preset: **1,0 M / 1,5 M / 2,3 M / 3,7 M** (low/medium/high/ultra). Nếu màn hình lớn hơn, độ phân giải nội bộ giảm theo `√(ngân sách / pixel)`, sau đó pass cuối **upscale** lên kích thước thật.

### 16.3 Dynamic resolution scaling

- Sau khoảng **3.5 giây ổn định**, game đo **thời gian khung trung bình** (mỗi 45 khung hoặc 0.9 s).
- Nếu > **21.5 ms**: giảm scale 0.1 (hoặc 0.2 nếu > 30 ms, hoặc xuống thẳng 0.6 nếu > 45 ms); sàn là **0.6**.
- Nếu < **17.4 ms** và đã chờ đủ: tăng scale 0.1 lên tới 1.
- Thời gian chờ tăng gấp đôi (tối đa 60 s) nếu liên tục phải giảm → tránh dao động.
- Nếu đã ở scale tối thiểu mà vẫn > 26 ms hai lần → **hạ cả preset** (ultra→high→medium→low), và phát sự kiện `quality:auto`.

---

## 17. Âm thanh (góp phần cảm giác "đẹp" tổng thể)

Dựa trên Web Audio:

- **Convolution reverb** với **2 impulse response**: `ir_outdoor` và `ir_shed`; hai đường gửi khác nhau: **ngoài trời** và **nhà kho**, có độ gửi `world=0.9`, `near=0.32`, ...
- **Panner HRTF** cho âm thanh định vị 3D (`refDistance 3`, `rolloff 0.6`, `maxDistance 400`).
- **Bộ lọc lowpass master** (đặt 20 kHz mặc định, tần số thay đổi để mô phỏng bị che/ngạt).
- Có **compressor** và **waveshaper** ở bus chính.
- Tên buffer như `rain`, `whiz`, `reload_magout`, `reload_magin`, `reload_bolt`, `shell_bou…` và log `genMs` cho thấy **âm thanh được tạo trong code lúc khởi động** (không thấy file âm thanh nhúng). Mình chưa kiểm tra chi tiết phương pháp tổng hợp.
- Có một đường **render âm thanh offline** (`OfflineAudioContext`, 10 giây mặc định) với cảnh giả gồm hải âu và chó săn → dùng để xem trước/kiểm thử.

---

## 18. Cách tái tạo trong dự án khác

Thứ tự khuyến nghị (từ ít công mà hiệu quả cao nhất):

1. **Render HDR** vào render target `HalfFloatType`, tắt tone mapping của engine; tự làm tone mapping ở pass cuối.
2. **Tone map ACES/AgX + split-tone teal & orange + S-curve + nâng đen** (mục 10). Chỉ riêng bước này đã đổi hẳn "cảm giác phim".
3. **Bloom dual-filter** + trung bình Karis ở mức đầu (mục 8.1).
4. **Vignette + film grain có trọng số theo độ sáng + dither** (mục 10).
5. **Ánh sáng đặt có chủ đích**: một mặt trời thấp, màu ấm, bầu trời có hướng; IBL từ chính bầu trời (mục 3).
6. **PCSS** với Vogel disk + IGN + receiver-plane bias (mục 4).
7. **SSAO half-res** + blur bilateral, **chỉ che ánh sáng môi trường** (mục 5).
8. **Volumetric** ray-march half-res dùng shadow map, hàm pha hai thùy, mật độ giảm theo độ cao (mục 6).
9. **Eye adaptation** bằng trung bình log + metering tâm (mục 9).
10. **Hiệu ứng ống kính**: flare có kiểm tra che, dirt, streak, CA (mục 8).
11. **Bề mặt procedural**: noise + Voronoi + vết xước + mô hình hư hại sơn, **ướt mưa** (mục 11).
12. **Gắn hiệu ứng vào gameplay** (mục 15), rồi **dynamic resolution** (mục 16).

Mẹo quan trọng rút ra từ code:

- **Dùng chung IGN** (`fract(52.98 * fract(dot(p, (0.0671, 0.0058))))`) để xoay mẫu theo pixel ở AO, bóng, volumetric, motion blur → nhiễu có cấu trúc, dễ làm sạch.
- **Mọi blur đều nhận biết depth**; mọi upsample đều **bilateral**.
- **Chạy các pass tốn kém ở nửa độ phân giải** (AO, volumetric) rồi upsample thông minh.
- **Ép depth của súng vào 5% đầu** thay vì xử lý clipping.
- **Có đường lui** (fallback) và **tự đo hiệu năng** để không vỡ trên máy yếu.

---

## 19. Những gì chưa xác minh

- **Chưa chạy game để quan sát hình thực tế** hay đo FPS/pass; chưa dùng profiler.
- **Số dòng** chỉ gần đúng và phụ thuộc phiên bản file.
- **Tên biến** trong file là tên đã minify; mình đặt tên mô tả (như "viewmodel camera", "TUNE") dựa trên ngữ cảnh và comment.
- *Suy luận, chưa chứng minh*: albedo lưu `sqrt` để lọc chính xác hơn; mặt trời là "hoàng hôn" hay "bình minh" (code chỉ cho biết mặt trời thấp ~13°); ý nghĩa chính xác của từng phần tử trong bảng sóng biển `Db`.
- Chưa đọc hết mọi shader (ví dụ chi tiết từng loại bề mặt trong 27 loại, hệ thống chữ HUD, vật liệu súng, AI, vật lý).
- Chưa xác minh chi tiết **phương pháp tổng hợp âm thanh** (chỉ thấy tên buffer, thời gian sinh và cấu trúc bus).
- Một số hằng số (như `volSteps` tối thiểu 6) có thể bị ghi đè ở nơi khác trong code mà mình chưa tìm thấy.
