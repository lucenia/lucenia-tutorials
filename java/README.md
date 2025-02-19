# How to Connect to Lucenia with Java

If you are using the quick launch script to run a single node Lucenia you will need to add the certs to a trust store

```bash
 keytool -genkey -alias bmc -keyalg RSA -keystore KeyStore.jks -keysize 2048
```

You will need to enter a password for the keystore and then enter the information for the certificate. You can use the following command to view the certificate

```bash
keytool -list -v -keystore KeyStore.jks
```

If you are running the single node default security config lucenia you can get the root-ca pem from `~/.lucenia/lucenia-0.3.0/config/root-ca.pem`

You can add the root-ca.pem to the trust store with the following command

```bash
keytool -import -alias lucenia -file ~/.lucenia/lucenia-0.3.0/config/root-ca.pem -keystore KeyStore.jks
```

You will need to enter the password for the keystore and then enter `yes` to trust the certificate.

Verify the certificate is in the trust store with the following command

```bash
keytool -list -v -keystore KeyStore.jks
```
