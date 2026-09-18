# claude-rtl-kit — עברית מימין לשמאל ב־Claude Desktop

ערכה שמתקינה על מחשב חדש עותק של Claude Desktop עם תמיכה בעברית וערבית, ושומרת אותו
מעודכן אוטומטית אחרי כל עדכון של Claude. ה־Claude המקורי לא משתנה אף פעם.

## איך משתמשים

1. משכפלים את הריפו:

   ```bash
   git clone https://github.com/oshrychen/claude-rtl-kit-oshry.git ~/claude-rtl-kit-oshry
   ```

2. פותחים את Claude Desktop הרגיל, עוברים לטאב **Code**, ובוחרים את התיקייה הזו כתיקיית העבודה.
3. כותבים ל־Claude: **"תתקין את ערכת ה־RTL לפי ההוראות בתיקייה"**.
4. Claude קורא את `CLAUDE.md`, מזהה את מערכת ההפעלה, בודק את המחשב, מנקה פאטצ׳ים קודמים
   אם יש, מתקין, ומסביר מה לבדוק.

ב־Mac, בסוף סוגרים את Claude הרגיל ופותחים את `~/Applications/Claude-RTL.app`. אותו חשבון, אותן שיחות.

## מצב לפי מערכת הפעלה

| מערכת | מצב | מתקין |
|---|---|---|
| macOS 13+ | עובד, נבדק | `mac/install.sh` |
| Linux (Ubuntu/Debian, הבטא הרשמית) | בהכנה. `linux/PROMPT.md` מכיל את ההנחיות ליצירת המתקין | `linux/install.sh` (עדיין לא קיים) |

דרישות: Claude Desktop מותקן, Node.js 18 ומעלה, git. ב־Mac גם Xcode Command Line Tools.
אם משהו חסר, Claude יגיד מה ואיך להתקין.

## מה יש בריפו

- `CLAUDE.md` — ההוראות ל־Claude עצמו, ל־Mac ול־Linux. זה הקובץ החשוב.
- `mac/install.sh` — המתקין ל־Mac. אפשר גם ידנית: `bash mac/install.sh`, `--status`, `--check`, `--uninstall`.
- `mac/swap-when-quit.sh` — עוזר להחלפת האפליקציה כשהיא רצה בזמן ההתקנה.
- `linux/` — המתקין ל־Linux (יתווסף מהמכונה של Linux).
- `source/claude-desktop-rtl/` — קוד המקור של הפאטצ׳ (liorshaya/claude-desktop-rtl v0.2.21) עם תיקון נוסף לטאב ה־Code.
- `patches/0001-code-tab-surface.patch` — התיקון הנוסף כקובץ נפרד.
- `VERSIONS.md` — על איזה commit של upstream הערכה מבוססת.

## מגבלות ידועות

- Claude-RTL ו־Claude המקורי לא יכולים לרוץ במקביל. סוגרים אחד לפני שפותחים את השני.
- Artifacts בדסקטופ לא מכוסים.
- בפתיחה הראשונה ייתכן חלון ריק פעם אחת (לסגור ולפתוח) ואישור Keychain אחד.

## רישיון

קוד הפאטצ׳ ב־`source/` הוא של liorshaya/claude-desktop-rtl תחת רישיון MIT (ראה `source/claude-desktop-rtl/LICENSE`).
התיקון לטאב ה־Code הוא PR #3 של nioasoft לאותו פרויקט.
