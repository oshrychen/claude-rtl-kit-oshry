# Claude-RTL — עברית וערבית מימין לשמאל ב־Claude Desktop

**[English below](#english)**

פתרון מלא לעברית וערבית ב־Claude Desktop, ב־Mac וב־Linux. אחרי ההתקנה יש לך אפליקציה בשם
**Claude-RTL**, זהה לרגילה, עם אותו חשבון ואותן שיחות, שבה כל הטקסט מוצג בכיוון הנכון:

- **התשובות של Claude**: פסקאות, כותרות, רשימות, ציטוטים וטבלאות מיושרים לימין לפי התוכן,
  גם כשמשפט מתחיל באנגלית. קוד, נתיבים ונוסחאות בתוך משפט בעברית נשארים שלמים משמאל לימין.
- **ההודעות שלך**: מה שאתה כותב מוצג נכון, כולל משפטים מעורבים עברית־אנגלית, לינקים וסימני פיסוק,
  וגם תיבת הכתיבה עצמה.
- **טאב Code** (Claude Code בתוך האפליקציה): גם התשובות וגם ההודעות שלך, לא רק הצ׳אט הרגיל.
- **מתעדכן לבד**: אחרי כל עדכון של Claude העותק נבנה מחדש ברקע.

עובד על **Mac** ועל **Linux** (Ubuntu / Debian). ה־Claude המקורי לא משתנה, ואפשר להסיר הכל בפקודה אחת.

## התקנה: תן ל־Claude לעשות את זה

1. ודא ש־Claude Desktop הרשמי מותקן ([claude.com/download](https://claude.com/download)).
2. פתח את Claude Desktop, עבור לטאב **Code** למעלה, ובחר תיקייה כלשהי (למשל תיקיית הבית).
3. הדבק ל־Claude את ההודעה הזו:

   ```text
   תתקין לי עברית מימין לשמאל ב־Claude Desktop מהריפו הזה:
   https://github.com/oshrychen/claude-rtl-kit-oshry
   תשכפל אותו לתיקיית הבית שלי, תקרא את הקובץ CLAUDE.md שבתוכו, ותפעל לפיו עד הסוף.
   ```

4. Claude יבדוק מה חסר במחשב (ויגיד לך איך להשלים), ינקה התקנה קודמת אם יש, יתקין, ויסביר מה לבדוק.
5. בסוף סוגרים את Claude הרגיל ופותחים את **Claude-RTL**: ב־Mac מ־`~/Applications`, ב־Linux מתפריט האפליקציות.

זהו. מכאן והלאה, בכל פעם ש־Claude מתעדכן, Claude-RTL נבנה מחדש לבד ברקע.

<details>
<summary>מעדיפים טרמינל? התקנה ידנית</summary>

```bash
git clone https://github.com/oshrychen/claude-rtl-kit-oshry.git ~/claude-rtl-kit-oshry
cd ~/claude-rtl-kit-oshry
bash mac/install.sh        # Mac
bash linux/install.sh      # Linux
```

לכל מתקין יש גם `--check` (בדיקה בלי שינויים), `--status` ו־`--uninstall`.
</details>

## מה צריך שיהיה במחשב

- Claude Desktop הרשמי. ב־Mac מ־claude.com, ב־Linux החבילה `claude-desktop` מה־apt של Anthropic.
- **Node.js 18 ומעלה** ו־git. ב־Mac גם Xcode Command Line Tools. אם משהו חסר, Claude יגיד לך בדיוק מה ואיך.
- הטאב Code ב־Claude Desktop זמין בתוכניות שכוללות את Claude Code. אם אין לך, ההתקנה הידנית למעלה עושה את אותו דבר.

## מה זה עושה למחשב, ומה לא

| עושה | לא עושה |
|---|---|
| בונה **עותק** של Claude עם התיקון: ב־Mac `~/Applications/Claude-RTL.app`, ב־Linux `~/.local/lib/claude-rtl` | לא נוגע ב־Claude המקורי, לא בקבצי מערכת, לא צריך sudo |
| מתקין משימת רקע קטנה שבונה את העותק מחדש אחרי עדכון של Claude (Mac: LaunchAgent, Linux: systemd user unit) | לא שולח שום דבר לשום מקום, אין טלמטריה, אין רשת חוץ מהורדת כלי הבנייה |
| משנה רק את **הכיוון** של הטקסט על המסך | לא משנה את הטקסט עצמו, לא מוסיף תווים נסתרים |

הסרה: `bash mac/install.sh --uninstall` או `bash linux/install.sh --uninstall`. ה־Claude המקורי נשאר כמו שהיה.

## מגבלות ידועות

- Claude-RTL ו־Claude המקורי לא יכולים לרוץ **במקביל**, כי הם חולקים את אותן שיחות. סוגרים אחד לפני שפותחים את השני.
- Artifacts (המסמכים והאפליקציות ש־Claude מציג בחלון צד) לא מכוסים.
- בפתיחה הראשונה ייתכן חלון ריק פעם אחת (סוגרים ופותחים שוב) ואישור אחד של Keychain ב־Mac.
- אחרי עדכון גדול של Claude ייתכן שמבנה האפליקציה ישתנה והבנייה תיכשל. במקרה כזה Claude-RTL הקודם נשאר, ואפשר לפתוח Issue כאן עם היומן.

## קרדיט

הערכה הזו לא כתבה את הפאטצ׳, היא רק עוטפת אותו כך שאפשר להתקין בלי להבין את הפרטים.

- המנוע והפאטצ׳: **[liorshaya/claude-desktop-rtl](https://github.com/liorshaya/claude-desktop-rtl)** (גרסה 0.2.21), רישיון MIT. שם נמצא הקוד שמזהה כיוון, מטפל בטבלאות, ברשימות ובנוסחאות.
- התיקון לטאב ה־Code: [Pull Request #3](https://github.com/liorshaya/claude-desktop-rtl/pull/3) מאת nioasoft, שמור כאן ב־`patches/`.
- שאר הפרויקטים שנבדקו והובילו לבחירה: [shraga100](https://github.com/shraga100/claude-desktop-rtl-patch) (Windows), [soguy](https://github.com/soguy/claude-desktop-rtl-mac), [ikhd](https://github.com/ikhd/claude-desktop-rtl).

## אזהרה

זהו פרויקט קהילתי, לא קשור ל־Anthropic ולא מאושר על ידה. הוא בונה עותק של האפליקציה עם קוד
נוסף בתוכה, וייתכן שזה לא תואם את תנאי השימוש של Claude. השימוש על אחריותך. אם משהו לא עובד,
תמיד אפשר לחזור ל־Claude הרגיל, שלא נגעו בו.

---

<a id="english"></a>
# Claude-RTL — Hebrew & Arabic right-to-left for Claude Desktop

A complete right-to-left fix for Claude Desktop on macOS and Linux. After installing you
have an app called **Claude-RTL**, identical to the regular one (same login, same chats), in
which every piece of text runs in the right direction:

- **Claude's answers**: paragraphs, headings, lists, quotes and tables follow their content,
  even when a sentence opens with English. Code, paths and math inside an RTL sentence stay
  intact and left-to-right.
- **Your messages**: what you type renders correctly, including mixed Hebrew/Arabic and
  English, links and punctuation, and the input box itself.
- **The Code tab** (Claude Code inside the app): both the answers and your messages, not
  only the regular chat.
- **Keeps itself current**: after every Claude update the copy is rebuilt in the background.

Works on **macOS** and **Linux** (Ubuntu / Debian). The original Claude is never modified, and
everything can be removed with one command.

## Install: let Claude do it

1. Make sure the official Claude Desktop is installed ([claude.com/download](https://claude.com/download)).
2. Open Claude Desktop, switch to the **Code** tab, pick any folder (your home folder is fine).
3. Paste this message to Claude:

   ```text
   Install right-to-left (Hebrew/Arabic) support for Claude Desktop from this repo:
   https://github.com/oshrychen/claude-rtl-kit-oshry
   Clone it into my home folder, read the CLAUDE.md inside, and follow it to the end.
   ```

4. Claude checks what is missing (and tells you how to get it), cleans up any earlier RTL
   patch, installs, and tells you what to look at.
5. Quit the regular Claude and open **Claude-RTL**: on macOS from `~/Applications`, on Linux
   from the app menu.

That's it. From now on, whenever Claude updates itself, Claude-RTL is rebuilt in the background.

<details>
<summary>Prefer a terminal? Manual install</summary>

```bash
git clone https://github.com/oshrychen/claude-rtl-kit-oshry.git ~/claude-rtl-kit-oshry
cd ~/claude-rtl-kit-oshry
bash mac/install.sh        # macOS
bash linux/install.sh      # Linux
```

Each installer also has `--check` (no changes), `--status` and `--uninstall`.
</details>

## Requirements

- Official Claude Desktop: from claude.com on macOS, the `claude-desktop` package from
  Anthropic's apt repo on Linux.
- **Node.js 18+** and git. On macOS also the Xcode Command Line Tools. Claude tells you exactly
  what is missing and how to install it.
- The Code tab in Claude Desktop needs a plan that includes Claude Code. Without it, the
  manual install above does the same thing.

## What it changes on your machine, and what it doesn't

| Does | Doesn't |
|---|---|
| Builds a **copy** of Claude with the fix: macOS `~/Applications/Claude-RTL.app`, Linux `~/.local/lib/claude-rtl` | Never touches the original Claude or system files; no sudo |
| Installs a small background task that rebuilds the copy after a Claude update (macOS LaunchAgent, Linux systemd user unit) | Sends nothing anywhere: no telemetry, no network except downloading the build tools |
| Changes only the **direction** of text on screen | Never edits the text itself, never inserts hidden characters |

Removal: `bash mac/install.sh --uninstall` or `bash linux/install.sh --uninstall`. The
original Claude is left exactly as it was.

## Known limits

- Claude-RTL and the original Claude cannot run **at the same time** (they share the same
  conversations). Quit one before opening the other.
- Artifacts (the documents and apps Claude shows in a side panel) are not covered.
- The first launch may show a blank window once (quit and reopen) and one Keychain prompt on macOS.
- A big Claude update may change the app's layout and make the build fail. The previous
  Claude-RTL stays usable; open an issue here with the log.

## How it works, briefly

The chat inside Claude Desktop is the claude.ai web app. It already picks a direction for each
block of Claude's answers (from the first strong character), but it does nothing for your own
messages, the input box, the Code tab, inline code or math inside RTL text, or mixed-language
lines. The patch injects a small script into the app's renderer that covers all of those: it
detects the direction of every paragraph, list item and table cell, keeps code and math
left-to-right, and leaves what claude.ai already handles alone.
The installer unpacks the app's `app.asar`, adds the script to the renderer bundles, repacks
it into a separate copy of the app, and sets up a watcher that redoes this after updates.
Details: `CLAUDE.md` (the runbook Claude follows), `linux/README.md` (Linux specifics),
`VERSIONS.md` (exact upstream commits).

## Credits

This kit does not implement the RTL logic; it packages it so anyone can install it.

- Engine and patch: **[liorshaya/claude-desktop-rtl](https://github.com/liorshaya/claude-desktop-rtl)**
  (v0.2.21), MIT. That is where direction detection, tables, lists and math handling live.
- Code-tab fix: [pull request #3](https://github.com/liorshaya/claude-desktop-rtl/pull/3) by
  nioasoft, kept here under `patches/`.
- Other projects evaluated along the way: [shraga100](https://github.com/shraga100/claude-desktop-rtl-patch)
  (Windows), [soguy](https://github.com/soguy/claude-desktop-rtl-mac), [ikhd](https://github.com/ikhd/claude-desktop-rtl).

## Disclaimer

Community project, not affiliated with or endorsed by Anthropic. It builds a copy of the app
with extra code inside, which may not comply with Claude's terms of service. Use at your own
risk. If anything goes wrong, the untouched original Claude is still there.

## License

MIT for the kit (see `LICENSE`). The vendored engine keeps its own MIT license in
`source/claude-desktop-rtl/LICENSE`.
