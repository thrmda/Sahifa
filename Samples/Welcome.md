# Welcome to Sahifa — أهلًا بك في صحيفة

Sahifa is a calm, native macOS Markdown editor where English and Arabic are
**equal citizens** on one page. Two scripts, two directions, one surface.

هذه فقرة عربية. لاحظ أنها تبدأ من اليمين تلقائيًا، بينما تبقى الفقرة
الإنجليزية أعلاه تبدأ من اليسار — كل فقرة تكتشف اتجاهها من أول حرف قوي فيها،
تمامًا مثل `dir="auto"` في HTML.

## Mixed inline text — نص مختلط

You can write English with كلمات عربية في الوسط and the system engine keeps
the caret, selection, and shaping correct. And here is a paragraph that
mentions **التنسيق الغامق** and *المائل* inline.

وبالمثل يمكن كتابة فقرة عربية تحتوي على words in English مع روابط مثل
[موقع آبل](https://www.apple.com) وكود مضمّن مثل `let x = 42` — الكود دائمًا
من اليسار إلى اليمين.

### Lists — القوائم

- First item in English
- عنصر ثانٍ بالعربية
- Third item mixing نصًا عربيًا with English

1. Ordered item
2. عنصر مرقّم بالعربية

### Code — الكود

```swift
// Code blocks are always LTR + monospace, even in Arabic documents.
let greeting = "مرحبا"
print(greeting)
```

> A quote in English.
> اقتباس بالعربية.

---

Plain text on disk. No database, no lock-in. ملفاتك ملكك.
