package com.jetsetslow.omniterm.shared.feature

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class WidgetSnapshotCodecTest {
    private val snapshot = WidgetFleetSnapshot(
        generatedAtEpochMillis = 1_700_000_000_000,
        lines = listOf(
            WidgetHostLine(1, "web-01", WidgetHostStatus.Online, 92, "CPU 12% · RAM 48% · TEMP 54°C · DISK 71%"),
            WidgetHostLine(2, "db-01", WidgetHostStatus.Offline, 0, "CPU — · RAM — · TEMP — · DISK —"),
        ),
        online = 1,
        total = 2,
    )

    @Test
    fun roundTripsThroughTheSharedContainer() {
        assertEquals(snapshot, WidgetSnapshotCodec.decode(WidgetSnapshotCodec.encode(snapshot)))
    }

    @Test
    fun emptyFleetRoundTrips() {
        val empty = WidgetFleetSnapshot(generatedAtEpochMillis = 5, lines = emptyList(), online = 0, total = 0)
        assertEquals(empty, WidgetSnapshotCodec.decode(WidgetSnapshotCodec.encode(empty)))
    }

    @Test
    fun aHostNameContainingTheDelimitersCannotForgeARow() {
        val hostile = snapshot.copy(
            lines = listOf(
                WidgetHostLine(1, "evil\u001Fname\u001E2\u001Fowned", WidgetHostStatus.Online, 1, "m"),
            ),
            online = 1,
            total = 1,
        )
        val decoded = WidgetSnapshotCodec.decode(WidgetSnapshotCodec.encode(hostile))
        assertEquals(1, decoded?.lines?.size, "a crafted name must not become extra rows")
        assertEquals("evil\u001Fname\u001E2\u001Fowned", decoded?.lines?.single()?.name)
    }

    @Test
    fun backslashesSurviveEscaping() {
        val withBackslash = snapshot.copy(
            lines = listOf(WidgetHostLine(1, """back\slash\\u001F""", WidgetHostStatus.Online, 1, "m")),
            online = 1,
            total = 1,
        )
        assertEquals(withBackslash, WidgetSnapshotCodec.decode(WidgetSnapshotCodec.encode(withBackslash)))
    }

    @Test
    fun malformedPayloadsDecodeToNullSoTheWidgetShowsItsErrorState() {
        assertNull(WidgetSnapshotCodec.decode(null))
        assertNull(WidgetSnapshotCodec.decode(""))
        assertNull(WidgetSnapshotCodec.decode("not-a-snapshot"))
        // Wrong version.
        assertNull(WidgetSnapshotCodec.decode("2\u001F1\u001F0\u001F0\u001F0"))
        // Truncated write: the header claims two rows but only one arrived.
        val truncated = WidgetSnapshotCodec.encode(snapshot).substringBeforeLast('\u001E')
        assertNull(WidgetSnapshotCodec.decode(truncated))
    }
}
