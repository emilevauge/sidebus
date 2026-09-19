package app.sidebus.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeTest {

    @Test
    fun codeDeriveDesQuatrePremiersOctets() {
        // 0x00 0x0F 0x42 0x40 = 1,000,000 -> 000000 after the modulo.
        assertEquals("000000", DeviceIdentity.pairingCode(byteArrayOf(0x00, 0x0F, 0x42, 0x40, -1)))
        // 0x00 0x00 0x30 0x39 = 12 345.
        assertEquals("012345", DeviceIdentity.pairingCode(byteArrayOf(0x00, 0x00, 0x30, 0x39)))
    }

    @Test
    fun codeToujoursSurSixChiffres() {
        for (byte in 0..32) {
            val value = byte.toByte()
            val code = DeviceIdentity.pairingCode(byteArrayOf(value, value, value, value))
            assertEquals(6, code.length)
            assertTrue(code.all { it.isDigit() })
        }
    }

    /** Same vector as the Swift test `testVectorSharedWithAndroid`. */
    @Test
    fun pairingCodeIdentiqueAuMac() {
        val fingerprint = ByteArray(32) { it.toByte() }
        assertEquals("066051", DeviceIdentity.pairingCode(fingerprint))
    }
}
