package app.sroka.core.data

import app.sroka.core.data.ops.WireOp
import app.sroka.core.model.ItemStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class WireOpTest {
    @Test fun shapesMatchApiSection71() {
        val cases = listOf(
            WireOp.Add("o1", "i1", 5, "https://e.com/a", "T", listOf("travel"), "share", 5) to
                """{"opId":"o1","type":"item.add","itemId":"i1","at":5,"url":"https://e.com/a","title":"T","tags":["travel"],"source":"share","savedAt":5,"onDuplicate":"readd"}""",
            WireOp.SetStatus("o2", "i1", 6, ItemStatus.ARCHIVED) to
                """{"opId":"o2","type":"item.setStatus","itemId":"i1","at":6,"status":"archived"}""",
            WireOp.SetFavorite("o3", "i1", 7, true) to
                """{"opId":"o3","type":"item.setFavorite","itemId":"i1","at":7,"value":true}""",
            WireOp.SetProgress("o4", "i1", 8, 0.5f, 17) to
                """{"opId":"o4","type":"item.setProgress","itemId":"i1","at":8,"progress":0.5,"anchor":17}""",
            WireOp.Tag("o5", "i1", 9, "to-cook", true) to
                """{"opId":"o5","type":"item.tag","itemId":"i1","at":9,"tag":"to-cook","present":true}""",
            WireOp.SetTitle("o6", "i1", 10, null) to
                """{"opId":"o6","type":"item.setTitle","itemId":"i1","at":10,"title":""}""",
            WireOp.TagRename("o7", 11, "ml", "machine-learning") to
                """{"opId":"o7","type":"tag.rename","at":11,"from":"ml","to":"machine-learning"}""",
            WireOp.TagDelete("o8", 12, "old") to """{"opId":"o8","type":"tag.delete","at":12,"tag":"old"}""",
            WireOp.Delete("o9", "i1", 13) to """{"opId":"o9","type":"item.delete","itemId":"i1","at":13}""",
            WireOp.Refresh("b0", "i1", 14) to """{"opId":"b0","type":"item.refresh","itemId":"i1","at":14}""",
        )
        for ((op, json) in cases) {
            assertEquals(json, op.payload())
            assertEquals(op, WireOp.parse(json))
        }
    }

    @Test fun unknownOrCorruptPayloadIsNull() {
        assertEquals(null, WireOp.parse("""{"opId":"x","type":"item.future","at":1}"""))
        assertEquals(null, WireOp.parse("not json"))
    }
}
