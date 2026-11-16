import Foundation
import Testing
@testable import DatabaseManagerPlugin

// P5-3c 对象定义编辑离线单测：SQL 字面量转义、替换定义所用 DROP/CREATE 语句的写闸门识别。
// 真实引擎的例程/触发器编辑往返见 ObjectDefinitionIntegrationTests。

@Suite(.serialized)
struct DefinitionLiteralEscapeTests {
    @Test func doublesSingleQuotes() {
        #expect(DatabaseViewModel.escapeSQLLiteral("o'brien") == "o''brien")
        #expect(DatabaseViewModel.escapeSQLLiteral("plain") == "plain")
        #expect(DatabaseViewModel.escapeSQLLiteral("''") == "''''")
    }
}

@Suite(.serialized)
struct DefinitionWriteGateTests {
    @Test func mysqlRoutineAndTriggerReplacementIsWrite() {
        #expect(WriteGate.isWriteStatement("DROP PROCEDURE IF EXISTS `db`.`p`;", type: .mysql) == true)
        #expect(WriteGate.isWriteStatement("DROP FUNCTION IF EXISTS `db`.`f`;", type: .mysql) == true)
        #expect(WriteGate.isWriteStatement("DROP TRIGGER IF EXISTS `db`.`tr`;", type: .mysql) == true)
        #expect(WriteGate.isWriteStatement("CREATE PROCEDURE `db`.`p`() BEGIN SELECT 1; END", type: .mysql) == true)
        #expect(WriteGate.isWriteStatement("CREATE TRIGGER `db`.`tr` BEFORE INSERT ON `db`.`t` FOR EACH ROW SET NEW.x = 1", type: .mysql) == true)
    }

    @Test func postgresRoutineAndTriggerReplacementIsWrite() {
        #expect(WriteGate.isWriteStatement("CREATE OR REPLACE FUNCTION public.f() RETURNS integer AS $$ SELECT 1 $$ LANGUAGE sql;", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("DROP TRIGGER IF EXISTS \"tr\" ON \"public\".\"t\";", type: .postgresql) == true)
        #expect(WriteGate.isWriteStatement("CREATE TRIGGER tr BEFORE INSERT ON public.t FOR EACH ROW EXECUTE FUNCTION public.f();", type: .postgresql) == true)
    }

    @Test func readOnlyBlocksDefinitionReplacement() {
        #expect(WriteGate.decision(safeMode: .readOnly, isWrite: true) == .blocked)
        #expect(WriteGate.decision(safeMode: .confirmWrites, isWrite: true) == .requiresConfirmation)
        #expect(WriteGate.decision(safeMode: .off, isWrite: true) == .proceed)
    }
}