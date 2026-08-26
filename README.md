# PeptiKing Biohacking Course Downloader

PowerShell tools for downloading LearningSuite videos that your account can access.

## Output layout

The primary workflow creates this simple structure:

```text
Biohacking/
  Biohacking - Essentials/
    Training/
      Einführung.mp4
      Anatomie & Bewegung.mp4
    Ernährung/
      Kalorien.mp4
  Biohacking Praxis/
    Schlafoptimierung/
      Grundverständnis.mp4
```

Each course contains its module folders. Lesson videos are stored directly in their module and use the lesson title shown on LearningSuite.

## Requirements

- Windows 10 or 11
- Google Chrome
- Windows PowerShell 5.1 or newer
- FFmpeg and FFprobe available in `PATH`, `C:\ffmpeg\bin`, or the supported `C:\ffmpeg\ffmpeg-*-essentials_build\bin` location
- A LearningSuite account with access to the requested course

## Step 1: create a course structure

Run the structure script with the course URL:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\1-create-course-structure.ps1" "COURSE_URL" -OutputRoot "$env:USERPROFILE\Documents\Biohacking"
```

On the first run, log in inside the dedicated Chrome window, return to PowerShell, and press Enter. The script creates module folders plus `course-structure.csv` and `course-structure.json`. It does not download videos.

After the first login, add `-Automatic` when creating other course structures.

## Step 2: migrate and download missing videos

Pass the course folder created by step 1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\2-download-missing-videos.ps1" "$env:USERPROFILE\Documents\Biohacking\Biohacking - Essentials"
```

The script performs these actions in order:

1. Reads `course-structure.csv`.
2. Finds matching completed videos in the legacy `Documents\BiohackingCourse` folder.
3. Moves and renames those videos into the new structure.
4. Skips videos already present in the new structure.
5. Downloads only the missing videos.
6. Updates `download-status.csv` and `download-status.json` after every lesson.

Rerun the same command at any time to resume. Never add `-Force`; the new downloader does not need it.

### Migration options

- Default: `-MigrationMode Move`
- Keep the legacy copy: `-MigrationMode Copy`
- Ignore the legacy folder: `-MigrationMode None`
- Only reorganize existing files without downloading: `-MigrationOnly`

The Move mode refuses to run while a legacy downloader is active, preventing an old process from redownloading moved files.

## Course URLs

- Mini-Masterclass Peptide: `https://biohacking.learningsuite.io/student/course/mini-masterclass-peptide/TlbR5YFm`
- Biohacking Essentials: `https://biohacking.learningsuite.io/student/course/biohacking-essentials/YCSwPfWB`
- Biohacking Praxis: `https://biohacking.learningsuite.io/student/course/biohacking-praxis/dwfpzvnB`
- Biohacking Bibliothek: `https://biohacking.learningsuite.io/student/course/biohacking-bibliothek/wCmk81lS`

## Primary scripts

- `scripts\1-create-course-structure.ps1`
- `scripts\2-download-missing-videos.ps1`

The remaining scripts provide the underlying single-video download and the older downloader workflow.
