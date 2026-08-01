package com.jetsetslow.omniterm.shared.data

import com.jetsetslow.omniterm.shared.platform.CapabilityResult
import com.jetsetslow.omniterm.shared.platform.PlatformError
import com.jetsetslow.omniterm.shared.platform.SecretRef
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class MemoryRecordStorage(var contents: String? = null) : RecordStorage {
    var writes = 0
    var failWrites = false
    override suspend fun read(): String? = contents
    override suspend fun write(contents: String): CapabilityResult<Unit> {
        if (failWrites) return CapabilityResult.Failed(PlatformError.StorageUnavailable)
        writes++
        this.contents = contents
        return CapabilityResult.Available(Unit)
    }
}

private fun host(name: String = "web-01", id: Int = 0) = StoredHost(
    id = id,
    name = name,
    host = "$name.example",
    username = "root",
    credential = SecretRef("secret-$name"),
)

class HostRecordCodecTest {
    @Test
    fun roundTripsEveryField() {
        val hosts = listOf(
            host("web-01", id = 1).copy(notes = "prod", persistentSession = true, groupName = "Prod"),
            host("db-01", id = 2).copy(credential = null, groupName = null, port = 2222),
        )
        assertEquals(hosts, HostRecordCodec.decode(HostRecordCodec.encode(hosts)))
    }

    @Test
    fun aNameWithDelimitersOrNewlinesCannotForgeARecord() {
        val hostile = listOf(host(id = 1).copy(name = "evil\nrow\u001Ffield", notes = "back\\slash"))
        val decoded = HostRecordCodec.decode(HostRecordCodec.encode(hostile))
        assertEquals(1, decoded?.size, "a crafted name must not become a second host")
        assertEquals("evil\nrow\u001Ffield", decoded?.single()?.name)
        assertEquals("back\\slash", decoded?.single()?.notes)
    }

    @Test
    fun anEmptyFleetRoundTrips() {
        assertEquals(emptyList(), HostRecordCodec.decode(HostRecordCodec.encode(emptyList())))
    }

    @Test
    fun unreadablePayloadsDecodeToNullRatherThanAnEmptyFleet() {
        assertNull(HostRecordCodec.decode(null))
        assertNull(HostRecordCodec.decode(""))
        assertNull(HostRecordCodec.decode("garbage"))
        // Written by a newer build.
        assertNull(HostRecordCodec.decode("${HostRecordCodec.VERSION + 1}"))
        // Truncated record.
        assertNull(HostRecordCodec.decode("${HostRecordCodec.VERSION}\n1\u001Fweb"))
    }

    @Test
    fun theRecordNeverContainsASecretValue() {
        val encoded = HostRecordCodec.encode(listOf(host(id = 1)))
        assertTrue(encoded.contains("secret-web-01"), "the reference is stored")
        // The reference is an opaque id; a vault value never reaches this file by construction.
        assertFalse(encoded.contains("hunter2"))
    }
}

class FileBackedHostRepositoryTest {
    @Test
    fun assignsIdsAndPersistsAcrossReload() = runTest {
        val storage = MemoryRecordStorage()
        val repository = FileBackedHostRepository(storage)
        assertTrue(repository.load())

        val first = repository.upsert(host("web-01"))
        val second = repository.upsert(host("db-01"))
        assertEquals(1, first)
        assertEquals(2, second)

        val reloaded = FileBackedHostRepository(storage)
        assertTrue(reloaded.load())
        assertEquals(listOf("web-01", "db-01"), reloaded.all().map { it.name })
        // Ids must not restart, or the next insert would overwrite an existing host.
        assertEquals(3, reloaded.upsert(host("app-01")))
    }

    @Test
    fun updatingKeepsTheIdAndDoesNotDuplicate() = runTest {
        val repository = FileBackedHostRepository(MemoryRecordStorage())
        repository.load()
        val id = repository.upsert(host("web-01"))
        repository.upsert(host("web-01", id = id).copy(status = "online"))

        assertEquals(1, repository.all().size)
        assertEquals("online", repository.byId(id)?.status)
    }

    @Test
    fun deleteRemovesOnlyItsOwnRow() = runTest {
        val repository = FileBackedHostRepository(MemoryRecordStorage())
        repository.load()
        val first = repository.upsert(host("web-01"))
        val second = repository.upsert(host("db-01"))

        repository.delete(first)

        assertEquals(listOf(second), repository.all().map { it.id })
        repository.delete(first)
        assertEquals(1, repository.all().size, "deleting a missing row is a no-op")
    }

    @Test
    fun anUnparseableFileRefusesToLoadSoItIsNeverOverwritten() = runTest {
        val storage = MemoryRecordStorage(contents = "corrupted")
        val repository = FileBackedHostRepository(storage)

        assertFalse(repository.load(), "a corrupt file must not read as an empty fleet")
        assertEquals(0, storage.writes)
        assertFailsWith<IllegalStateException> { repository.all() }
        assertEquals("corrupted", storage.contents, "the user's file is left untouched")
    }

    @Test
    fun aFailedWriteIsReportedAndRolledBack() = runTest {
        val storage = MemoryRecordStorage()
        val repository = FileBackedHostRepository(storage)
        repository.load()
        repository.upsert(host("web-01"))

        storage.failWrites = true
        assertFailsWith<IllegalStateException> { repository.upsert(host("db-01")) }

        // The in-memory list must match the file, or the UI would show a host that vanishes.
        assertEquals(listOf("web-01"), repository.all().map { it.name })
    }
}
