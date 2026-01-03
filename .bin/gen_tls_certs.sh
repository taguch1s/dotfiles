#!/bin/bash

# shellcheck disable=SC2059

# ※このスクリプトは、テスト用のTLS証明書を生成します。
# サーバー側に配置するファイル
# - サーバー証明書： server-cert.pem
# - 鍵　　　　　　： server-key.pem
# - CA証明書　　 ： ca.pem
# クライアント側に配置するファイル
# - クライアント証明書： client-cert.pem
# - 鍵　　　　　　　　： client-key.pem
# - CA証明書　　　　 ： ca.pem

# 生成したファイルの用途
# - 内部ネットワークでのセキュアな通信
# - テスト環境でのSSL/TLS設定
# - クライアント証明書認証 (Mutual TLS)：クライアント証明書を用いた双方向のTLS認証
# - サーバー証明書と鍵：Webサーバーの設定で使用　※ただし自己署名証明書
# - dhparam.pem：Webサーバーの設定で使用、ForwardSecrecy(前方秘匿性)の実現

# ------------------------------------------------------------
# nginxでmTLSを設定する例

# http {
#     server {
#         listen 443 ssl;
#         ssl_certificate /etc/nginx/ssl/server-cert.pem;
#         ssl_certificate_key /etc/nginx/ssl/server-key.pem;
#         ssl_client_certificate /etc/nginx/ssl/ca.pem;
#         ssl_verify_client on;
#         location / {
#             return 200 "Mutual TLS Authentication Successful!\n";
#         }
#     }
# }

# ------------------------------------------------------------
# mysqlでmTLSを設定する例

# mysql> CREATE USER 'myuser'@'myhost' REQUIRE SUBJECT 'CN=myuser';
# mysql> ALTER USER 'myuser'@'myhost' REQUIRE SUBJECT 'CN=myuser';

# ------------------------------------------------------------

CN_CA="example.local" # 主体名
CN_SERVER="example.local" # ドメイン名やサービス名
CN_CLIENT="user" # ユーザー名やサービス名
OWNER="999" # 一般的に 101:nginx, 999:mysql
PFX_PASSWORD="password"

# 有効期限は10年

# 完全なsubjectを指定する場合
# "/C=JP/ST=Tokyo/L=Chiyoda-ku/O=Example Inc/OU=IT Department/CN=example.com Root CA"

function gen_rsa {
  # CA証明書の作成（RSA）
  openssl genpkey -algorithm RSA -out ca-key.pem
  openssl req -new -x509 -key ca-key.pem -out ca.pem -days 3650 -subj "/CN=${CN_CA} Root CA" # 自己署名証明書の場合、一般的にはRoot CA（ルート証明書）に該当する

  # サーバー用の証明書とキーの作成（RSA）
  openssl req -newkey rsa:2048 -days 3650 -nodes -keyout server-key.pem -out server-req.pem -subj "/CN=${CN_SERVER}"
  openssl x509 -req -in server-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem -set_serial 01 -out server-cert.pem

  # クライアント用の証明書とキーの作成（RSA）
  openssl req -newkey rsa:2048 -days 3650 -nodes -keyout client-key.pem -out client-req.pem -subj "/CN=${CN_CLIENT}"
  openssl x509 -req -in client-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem -set_serial 02 -out client-cert.pem
}

function gen_rsa_san {
  # /etc/ssl/opnessl.cnfの設定例
  # [ v3_ca ]
  # subjectAltName = @alt_names
  # [ alt_names ]
  # DNS.1 = example.com
  # DNS.2 = www.example.com

  # CAのキーと証明書の作成（SAN指定なし）
  openssl genpkey -algorithm RSA -out ca-key.pem
  openssl req -new -x509 -key ca-key.pem -out ca.pem -days 3650 -subj "/CN=${CN_CA} Root CA"

  # サーバー用の証明書とキーの作成（SAN指定）
  openssl req -newkey rsa:2048 -days 3650 -nodes -keyout server-key.pem -out server-req.pem -subj "/CN=${CN_SERVER}_server" -config <(cat /etc/ssl/openssl.cnf <(printf "\n[SAN]\nsubjectAltName=DNS:${CN_SERVER}"))
  openssl x509 -req -in server-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem -set_serial 01 -out server-cert.pem -extensions SAN -extfile <(printf "subjectAltName=DNS:${CN_SERVER}")

  # クライアント用の証明書とキーの作成（SAN指定）
  openssl req -newkey rsa:2048 -days 3650 -nodes -keyout client-key.pem -out client-req.pem -subj "/CN=${CN_CLIENT}_client" -config <(cat /etc/ssl/openssl.cnf <(printf "\n[SAN]\nsubjectAltName=DNS:${CN_CLIENT}"))
  openssl x509 -req -in client-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem -set_serial 02 -out client-cert.pem -extensions SAN -extfile <(printf "subjectAltName=DNS:${CN_CLIENT}")
}

function gen_ecdsa {
  # CA証明書の作成 (ECDSA、P-384曲線を使用)
  openssl ecparam -name prime256v1 -genkey -out ca-key.pem
  openssl req -new -x509 -key ca-key.pem -out ca.pem -days 3650 -sha256 -subj "/CN=${CN_CA} Root CA"

  # サーバー用の証明書とキーの作成 (ECDSA、P-384曲線を使用)
  openssl ecparam -name prime256v1 -genkey -out server-key.pem
  openssl req -new -key server-key.pem -out server-req.pem -subj "/CN=${CN_SERVER}_server"
  openssl x509 -req -in server-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem -set_serial 01 -sha256 -out server-cert.pem

  # クライアント用の証明書とキーの作成 (ECDSA、P-384曲線を使用)
  openssl ecparam -name prime256v1 -genkey -out client-key.pem
  openssl req -new -key client-key.pem -out client-req.pem -subj "/CN=${CN_CLIENT}_client"
  openssl x509 -req -in client-req.pem -days 3650 -CA ca.pem -CAkey ca-key.pem -set_serial 02 -sha256 -out client-cert.pem

  # Diffie-Hellman パラメータの生成 (鍵交換の強化)
  openssl dhparam -out dhparam.pem 4096
}

function gen_pfx {
  # PFXファイルの作成
  openssl pkcs12 -export \
    -out output.pfx \
    -inkey client-key.pem \
    -in client-cert.pem \
    -certfile ca.pem \
    -passout pass:${PFX_PASSWORD}
}

function main {
  mkdir certs
  cd certs || exit

  gen_rsa # RSA
  # gen_rsa_san # RSA ※SAN (Subject Alternative Name)
  # gen_ecdsa # ECDSA ※時間がかかる
  # gen_pfx # PFX

  sudo chmod 0600 ./*
  sudo chown "${OWNER}:${OWNER}" ./*
  cd ..
}

main
