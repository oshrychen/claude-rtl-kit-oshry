# פרומט להתאמת פאטצ׳ ה־RTL ל־Linux

## הכנה על מכונת ה־Linux

1. לשכפל את הריפו:

   ```bash
   git clone https://github.com/oshrychen/claude-rtl-kit-oshry.git ~/claude-rtl-kit-oshry
   ```

2. לפתוח את Claude Desktop ב־Linux, לעבור לטאב Code, ולבחור את `~/claude-rtl-kit-oshry` כתיקיית עבודה.
3. להדביק את הטקסט שבבלוק למטה.

בסוף התהליך תיקיית `linux/` בריפו תכיל מתקין עובד, `CLAUDE.md` יעודכן, והכל יידחף ל־GitHub.
ב־Mac מספיק `git pull` כדי לקבל את זה.

## הפרומט

```text
אני רוצה להתאים ל־Linux את פאטצ׳ ה־RTL לעברית של Claude Desktop שבריפו הזה, ולהוסיף את המתקין ל־Linux לאותו ריפו.

תקרא קודם את CLAUDE.md, VERSIONS.md ואת mac/install.sh. תיקיית linux/ מכילה כרגע רק את הקובץ הזה.

מה יש בריפו:
- source/claude-desktop-rtl הוא liorshaya/claude-desktop-rtl v0.2.21 עם תיקון נוסף לטאב ה־Code (patches/0001-code-tab-surface.patch, כבר מוחל על הקבצים). הפרויקט תומך רק ב־macOS ו־Windows, והסקריפט שלו נעצר על Linux בבדיקת uname ב־desktop/preflight.sh.
- mac/install.sh מראה את הרצף המדויק שאני רוצה לשכפל: בדיקת סביבה, סריקת פאטצ׳ים קודמים, העתקת המקור לתיקייה קבועה, טסטים, בנייה, מנגנון עדכון אוטומטי, אימות. אל תשנה את קבצי ה־Mac.

רקע שכבר ידוע:
- Claude Desktop ל־Linux היא בטא רשמית של Anthropic מיוני 2026, מותקנת דרך apt (חבילת claude-desktop). תבדוק קודם איפה היא יושבת בפועל (dpkg -L claude-desktop) ואיזו גרסה.
- הצ׳אט נטען מהאתר claude.ai, ולאתר אין RTL מובנה בהודעות. לכן צריך את הפאטצ׳ גם כאן.
- מה שסקריפט ה־macOS (source/claude-desktop-rtl/desktop/patch.sh) עושה:
  1. בונה את ה־payload עם `node build/build-payload.js` לקובץ dist/payload.js (מסומן במחרוזת claude-rtl-payload-v1).
  2. מחלץ את app.asar עם @electron/asar, ומצרף את ה־payload לתחילת כל קובץ .vite/build/*.js חוץ מנקודת הכניסה של ה־main שנקראת מ־package.json (ב־Mac היא .vite/build/index.pre.js). לנקודת הכניסה מוסיף רק שורה של appendSwitch('force-ui-direction','ltr'). הזרקת ה־payload המלא ל־main גורמת למסך שחור.
  3. אורז מחדש עם --unpack לכל הקבצים שהמקור שומר ב־app.asar.unpacked, ומוודא שמספר הקבצים המסומנים unpacked זהה למקור.
  4. מכבה את ה־fuse EnableEmbeddedAsarIntegrityValidation עם @electron/fuses.
  5. חותם מחדש ב־codesign. ב־Linux השלב הזה לא רלוונטי.
- ב־macOS הפאטצ׳ בונה עותק נפרד של האפליקציה. ב־Linux תחליט אתה אם עותק נפרד או פאטצ׳ במקום, לפי מבנה ההתקנה, ותסביר את השיקול. אל תיגע בקבצים של החבילה בלי לגבות את app.asar המקורי קודם.

מה אני רוצה שתעשה:
1. תבנה את ה־payload מ־source/claude-desktop-rtl ותריץ את הטסטים (node --test engine/__tests__/*.test.js dom/__tests__/*.test.js build/__tests__/*.test.js), אמורים לעבור 606.
2. תכתוב linux/install.sh על בסיס mac/install.sh ו־desktop/patch.sh, עם אותן בדיקות בטיחות (payload markers, unpacked count, גיבוי ושחזור), ועם --install, --status, --check, --uninstall. תסרוק גם פאטצ׳ים קודמים (למשל aaddrick/claude-desktop-debian או פאטצ׳י RTL אחרים) ותדווח לפני שאתה נוגע. תוסיף linux/README.md קצר.
3. תבדוק אם ה־fuse של שלמות ה־asar פעיל בבנייה ל־Linux, ותכבה אותו רק אם צריך.
4. תפתור את בעיית העדכונים: apt upgrade ידרוס את הפאטצ׳. תממש החלה מחדש אוטומטית (apt hook ב־/etc/apt/apt.conf.d או systemd path unit ברמת המשתמש), מקביל ל־LaunchAgent של macOS, ותתעד איך מכבים אותה.
5. תריץ את ההתקנה, תוודא שהאפליקציה עולה עם חלון ולא מסך שחור, ותגיד לי בדיוק מה לבדוק בעיניים: משפט מעורב עברית־אנגלית, רשימה, טבלה וציטוט בטאב הצ׳אט, וגם הודעה שלי בטאב ה־Code.
6. אחרי שאאשר שהכל עובד: תעדכן את סעיף Linux ב־CLAUDE.md ואת הטבלה ב־README.md, תוסיף שורה ל־VERSIONS.md עם גרסת Claude ל־Linux שנבדקה, ותעשה commit ו־push לריפו עם הודעה ברורה. תשאיר את הקובץ הזה במקומו לתיעוד.

מגבלה ידועה שלא צריך לתקן: Artifacts בדסקטופ לא מכוסים. אם אתה רץ מתוך העותק המתוקן עצמו, אל תחליף אותו בזמן ריצה; תבנה ליד ותחליף אחרי סגירה, כמו ש־mac/swap-when-quit.sh עושה. לזיהוי תהליכים תשתמש ב־ps ולא ב־pgrep, כי pgrep לא רואה את התהליך הראשי של האפליקציה שמארחת אותך.
```

דרישות על מכונת ה־Linux: Node.js 18 ומעלה, git עם הרשאת push לריפו (gh auth login או SSH key),
וגישה ל־sudo אם ההתקנה של Claude נמצאת תחת /usr או /opt.
