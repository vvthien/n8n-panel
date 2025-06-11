# N8N Cloud Manager

## Giới thiệu

N8N Cloud Manager là công cụ hỗ trợ quản lý N8N trên CloudFly, bao gồm các chức năng như cài đặt, nâng cấp, xuất/nhập dữ liệu, và cấu hình hệ thống.

Phát triển bởi   
![CloudFly Logo](https://cloudfly.vn/_next/image?url=%2Fimage%2Flogo%2Flogo.webp&w=256&q=75)

---

## Cách sử dụng

### 1. Cài đặt công cụ

Chạy lệnh sau để cài đặt công cụ:

```bash
sudo bash install.sh
```

### 2. Các chức năng chính

Sau khi cài đặt, bạn có thể sử dụng công cụ bằng cách chạy lệnh:

```bash
n8n-host
```

Công cụ sẽ hiển thị menu chính với các chức năng sau:

| **Số** | **Chức năng**                              |
| ------ | ------------------------------------------ |
| 1      | Cài đặt N8N                                |
| 2      | Thay đổi tên miền                          |
| 3      | Nâng cấp phiên bản N8N                     |
| 4      | Tắt xác thực 2 bước (2FA/MFA)              |
| 5      | Đặt lại thông tin đăng nhập                |
| 6      | Export tất cả (workflows & credentials)    |
| 7      | Import workflows & credentials từ template |
| 8      | Lấy thông tin Redis                        |
| 9      | Xóa N8N và cài đặt lại                     |

---

### 3. Hướng dẫn sử dụng các chức năng

#### **Cài đặt N8N**

1. Chọn `1) Cài đặt N8N` từ menu.
2. Nhập tên miền bạn muốn sử dụng (ví dụ: `n8n.example.com`).
3. Công cụ sẽ tự động cài đặt và cấu hình N8N trên server.

#### **Thay đổi tên miền**

1. Chọn `2) Thay đổi tên miền` từ menu.
2. Nhập tên miền mới.
3. Công cụ sẽ cập nhật cấu hình và cấp lại chứng chỉ SSL.

#### **Nâng cấp phiên bản N8N**

1. Chọn `3) Nâng cấp phiên bản N8N` từ menu.
2. Công cụ sẽ tải phiên bản mới nhất từ Docker Hub và khởi động lại N8N.

#### **Tắt xác thực 2 bước (2FA/MFA)**

1. Chọn `4) Tắt xác thực 2 bước (2FA/MFA)` từ menu.
2. Nhập email của tài khoản cần tắt 2FA.
3. Công cụ sẽ thực hiện tắt 2FA cho tài khoản.

#### **Đặt lại thông tin đăng nhập**

1. Chọn `5) Đặt lại thông tin đăng nhập` từ menu.
2. Công cụ sẽ reset thông tin tài khoản owner và yêu cầu tạo lại tài khoản khi truy cập N8N.

#### **Export tất cả (workflows & credentials)**

1. Chọn `6) Export tất cả (workflows & credentials)` từ menu.
2. Công cụ sẽ xuất dữ liệu và cung cấp đường dẫn tải xuống.

#### **Import workflows & credentials từ template**

1. Chọn `7) Import workflows & credentials` từ menu.
2. Công cụ sẽ import dữ liệu từ file template `import-workflow-credentials.json`.

#### **Lấy thông tin Redis**

1. Chọn `8) Lấy thông tin Redis` từ menu.
2. Công cụ sẽ hiển thị thông tin kết nối Redis.

#### **Xóa N8N và cài đặt lại**

1. Chọn `9) Xóa N8N và cài đặt lại` từ menu.
2. Công cụ sẽ xóa toàn bộ dữ liệu và cài đặt lại N8N từ đầu.

---

### 4. Gỡ bỏ công cụ

Để gỡ bỏ công cụ, chạy lệnh:

```bash
n8n-host --uninstall
```

---

## Tài liệu tham khảo

- [Hướng dẫn sử dụng N8N Cloud](https://cloudfly.vn/link/n8n-cloud-docs)
