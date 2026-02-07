package com.kuurier.app.core.crypto

import android.util.Base64
import com.kuurier.app.core.storage.SecureStorage
import net.i2p.crypto.eddsa.EdDSAEngine
import net.i2p.crypto.eddsa.EdDSAPrivateKey
import net.i2p.crypto.eddsa.EdDSAPublicKey
import net.i2p.crypto.eddsa.KeyPairGenerator
import net.i2p.crypto.eddsa.spec.EdDSANamedCurveTable
import net.i2p.crypto.eddsa.spec.EdDSAPrivateKeySpec
import net.i2p.crypto.eddsa.spec.EdDSAPublicKeySpec
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KeyManager @Inject constructor(
    private val secureStorage: SecureStorage
) {
    private val spec = EdDSANamedCurveTable.getByName(EdDSANamedCurveTable.ED_25519)

    fun generateKeyPair(): Pair<String, String> {
        val keyPairGenerator = KeyPairGenerator()
        val keyPair = keyPairGenerator.generateKeyPair()

        val publicKey = keyPair.public as EdDSAPublicKey
        val privateKey = keyPair.private as EdDSAPrivateKey

        val publicKeyBase64 = Base64.encodeToString(publicKey.abyte, Base64.NO_WRAP)
        val privateKeyBase64 = Base64.encodeToString(privateKey.seed, Base64.NO_WRAP)

        secureStorage.publicKey = publicKeyBase64
        secureStorage.privateKey = privateKeyBase64

        return Pair(publicKeyBase64, privateKeyBase64)
    }

    fun sign(message: String): String? {
        val privateKeyBase64 = secureStorage.privateKey ?: return null
        val seed = Base64.decode(privateKeyBase64, Base64.NO_WRAP)

        val privateKeySpec = EdDSAPrivateKeySpec(seed, spec)
        val privateKey = EdDSAPrivateKey(privateKeySpec)

        val engine = EdDSAEngine(MessageDigest.getInstance(spec.hashAlgorithm))
        engine.initSign(privateKey)
        engine.update(message.toByteArray(Charsets.UTF_8))

        val signature = engine.sign()
        return Base64.encodeToString(signature, Base64.NO_WRAP)
    }

    fun hasKeyPair(): Boolean {
        return secureStorage.publicKey != null && secureStorage.privateKey != null
    }

    fun getPublicKey(): String? = secureStorage.publicKey

    fun wipeKeys() {
        secureStorage.publicKey = null
        secureStorage.privateKey = null
    }
}
