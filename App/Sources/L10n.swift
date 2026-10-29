import Foundation

/// The app's words in English or Thai (Menu → Language). English is the key; Thai comes from
/// this table, and anything missing stays English.
enum L {
    static var thai: Bool { Settings.language == "th" }
    static func t(_ en: String) -> String { thai ? th[en] ?? en : en }

    private static let th: [String: String] = [
        // menu
        "Show": "แสดงตัว",
        "Hide": "ซ่อนตัว",
        "Call him": "เรียกมาหา",
        "Say something": "พูดอะไรหน่อย",
        "Miss you": "คิดถึงนะ",
        "Miss you code": "รหัสปุ่มคิดถึง",
        "Type the code he sent you. You only need to do this once.": "ใส่รหัสที่เค้าส่งให้ ใส่ครั้งเดียวพอ",
        "That code doesn't look right. Ask him to send it again.": "รหัสดูไม่ถูกนะ ขอให้เค้าส่งมาใหม่อีกที",
        "His last note…": "อ่านข้อความล่าสุดอีกครั้ง…",
        "Schedule / reminders…": "ตาราง / แจ้งเตือน…",
        "Anniversary letter…": "จดหมายวันครบรอบ…",
        "How to play…": "วิธีเล่น…",
        "Wake up": "ปลุก",
        "Sleep now": "ให้นอนเลย",
        "Size": "ขนาด",
        "Small": "เล็ก",
        "Medium": "กลาง",
        "Large": "ใหญ่",
        "%d min": "%d นาที",
        "Work or sleep when left alone": "ไปทำงาน (หรือนอนหลัง 4 ทุ่ม) เมื่อไม่มีใครเล่นด้วย",
        "Walk around": "เดินเล่นไปมา",
        "Edit lines…": "แก้ไขข้อความ…",
        "Open at login": "เปิดเองตอนเปิดเครื่อง",
        "Language": "ภาษา",
        "CPU usage…": "การใช้ CPU…",
        "Check for updates…": "ตรวจหาเวอร์ชันใหม่…",
        "Update Pug to %@…": "อัปเดต Pug เป็น %@…",
        "Quit": "ออก",
        "Close Window": "ปิดหน้าต่าง",
        "Edit": "แก้ไข",
        "Undo": "เลิกทำ",
        "Redo": "ทำซ้ำ",
        "Cut": "ตัด",
        "Copy": "คัดลอก",
        "Paste": "วาง",
        "Select All": "เลือกทั้งหมด",

        // windows
        "A letter for you": "จดหมายถึงเธอ",
        "How to play with Pug": "วิธีเล่นกับ Pug",
        "Pug's Schedule": "ตารางของ Pug",
        "CPU usage": "การใช้ CPU",

        // reminders
        "In 15 min:": "อีก 15 นาที:",
        "In 1 hour:": "อีก 1 ชั่วโมง:",
        "Tomorrow": "พรุ่งนี้",

        // CPU graphs
        "Whole Mac": "ทั้งเครื่อง",
        "all cores": "ทุกคอร์รวมกัน",
        "Pug": "Pug",
        "share of one core": "เทียบกับ 1 คอร์",
        "average": "เฉลี่ย",
        "2 min ago": "2 นาทีก่อน",
        "now": "ตอนนี้",

        // updates
        "Couldn't check for updates": "ตรวจหาเวอร์ชันใหม่ไม่ได้",
        "Check that you're online, then try again.": "ลองเช็กว่าต่อเน็ตอยู่ แล้วลองใหม่อีกครั้ง",
        "You have the newest Pug": "Pug เป็นเวอร์ชันล่าสุดแล้ว",
        "Version %@.": "เวอร์ชัน %@",
        "Pug %@ is ready": "Pug %@ พร้อมแล้ว",
        "You have %@. Pug closes for a moment, updates, and comes right back. Your plans and settings stay as they are.":
            "ตอนนี้เป็นเวอร์ชัน %@ Pug จะปิดไปแป๊บนึง อัปเดต แล้วกลับมาเอง ตารางและการตั้งค่ายังอยู่ครบ",
        "Update": "อัปเดต",
        "Later": "ไว้ทีหลัง",
        "OK": "ตกลง",
        "Pug couldn't update": "อัปเดต Pug ไม่สำเร็จ",
        "You can also download Pug.zip from github.com/Pug-03/Desktop-Pet-Pug and drag Pug into Applications.":
            "โหลด Pug.zip เองได้จาก github.com/Pug-03/Desktop-Pet-Pug แล้วลาก Pug ไปไว้ใน Applications",
        "The download didn't finish. Check that you're online, then try again.": "โหลดไม่เสร็จ ลองเช็กว่าต่อเน็ตอยู่ แล้วลองใหม่อีกครั้ง",
        "The downloaded file was damaged. Try again in a few minutes.": "ไฟล์ที่โหลดมาเสีย ลองใหม่อีกครั้งในอีกสักครู่",
        "GitHub is still sending the old version. Try again in a few minutes.": "GitHub ยังส่งเวอร์ชันเก่ามาอยู่ ลองใหม่อีกครั้งในอีกสักครู่",
        "Pug is running from Downloads. Drag Pug into your Applications folder, open it from there, then update.":
            "ตอนนี้เปิด Pug จากโฟลเดอร์ Downloads อยู่ ลาก Pug ไปไว้ใน Applications แล้วเปิดจากที่นั่น ค่อยอัปเดต",
        "Pug couldn't replace itself (%@).": "Pug เปลี่ยนเป็นตัวใหม่ไม่ได้ (%@)",
    ]

    static func t(_ en: String, _ args: CVarArg...) -> String { String(format: t(en), arguments: args) }
}
