package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class LongOperationSummaryTest {
    @Test
    fun aggregatesKnownConcurrentOperations() {
        val summary = summarizeLongOperations(
            listOf(
                LongOperationState("a", "Upload: a.iso", 40, 100),
                LongOperationState("b", "Download: b.tar", 10, 50),
            ),
        )

        assertThat(summary.count).isEqualTo(2)
        assertThat(summary.bytesDone).isEqualTo(50)
        assertThat(summary.totalBytes).isEqualTo(150)
        assertThat(summary.determinate).isTrue()
    }

    @Test
    fun oneUnknownSizeMakesTheAggregateIndeterminate() {
        val summary = summarizeLongOperations(
            listOf(
                LongOperationState("known", "Download: known", 40, 100),
                LongOperationState("unknown", "Upload: stream", 20, 0),
            ),
        )

        assertThat(summary.count).isEqualTo(2)
        assertThat(summary.bytesDone).isEqualTo(60)
        assertThat(summary.totalBytes).isEqualTo(0)
        assertThat(summary.determinate).isFalse()
    }

    @Test
    fun malformedNegativeProgressCannotReduceTheAggregate() {
        val summary = summarizeLongOperations(
            listOf(LongOperationState("a", "Upload: a", -1, 100)),
        )

        assertThat(summary.bytesDone).isEqualTo(0)
        assertThat(summary.totalBytes).isEqualTo(100)
        assertThat(summary.determinate).isTrue()
    }
}
