package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.ui.TransferAggregate
import org.junit.Test

class TransferAggregateTest {
    @Test
    fun fractionAndEtaAreBoundedForConcurrentProgressUpdates() {
        val aggregate = TransferAggregate(
            activeFiles = 3,
            bytesTransferred = 3L * 1024 * 1024,
            totalBytes = 8L * 1024 * 1024,
            speedKbps = 512f,
        )

        assertThat(aggregate.hasKnownTotal).isTrue()
        assertThat(aggregate.fraction).isWithin(0.0001f).of(0.375f)
        assertThat(aggregate.etaSeconds).isEqualTo(10)
        assertThat(aggregate.copy(bytesTransferred = Long.MAX_VALUE).fraction).isEqualTo(1f)
    }

    @Test
    fun unknownTotalsUseIndeterminateStateAndNeverInventEta() {
        val aggregate = TransferAggregate(2, 128 * 1024, 0, 256f)

        assertThat(aggregate.hasKnownTotal).isFalse()
        assertThat(aggregate.fraction).isEqualTo(0f)
        assertThat(aggregate.etaSeconds).isEqualTo(-1)
    }
}
