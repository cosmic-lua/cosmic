# tls fixtures

Certificates for the tests of [`cosmic.tls`] and the TLS listeners of
[`cosmic.net`]. The keys are for these tests alone: they guard nothing.

- `ca.pem`: a P-256 CA, "cosmic test CA", the root a test client trusts.
- `a.pem`, `a.key`: a P-256 leaf for `localhost` and `*.a.test`.
- `b.pem`, `b.key`: an RSA 2048 leaf for `b.test` and the IP address
  127.0.0.1.
- `c.pem`: `a.key`'s leaf again, valid only in January 2020, so expired.

Each leaf is signed by the CA and valid from 2026-01-01 to 2126-01-01
but `c.pem`. They were made with OpenSSL 3.0:

```sh
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 36500 -subj "/CN=cosmic test CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" -out ca.pem
openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out a.key
openssl genrsa -out b.key 2048
openssl req -new -key a.key -subj "/CN=localhost" -out a.csr
openssl req -new -key b.key -subj "/CN=b.test" -out b.csr
printf 'subjectAltName=DNS:localhost,DNS:*.a.test\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > a.ext
printf 'subjectAltName=DNS:b.test,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > b.ext
# ca.cnf: a minimal `openssl ca` configuration, policy commonName=supplied.
openssl ca -batch -config ca.cnf -cert ca.pem -keyfile ca.key -in a.csr -extfile a.ext -notext \
  -startdate 20260101000000Z -enddate 21260101000000Z -out a.pem
openssl ca -batch -config ca.cnf -cert ca.pem -keyfile ca.key -in b.csr -extfile b.ext -notext \
  -startdate 20260101000000Z -enddate 21260101000000Z -out b.pem
openssl ca -batch -config ca.cnf -cert ca.pem -keyfile ca.key -in a.csr -extfile a.ext -notext \
  -startdate 20200101000000Z -enddate 20200201000000Z -out c.pem
```

[`cosmic.net`]: ../../cosmic/net.tl
[`cosmic.tls`]: ../../cosmic/tls.tl
