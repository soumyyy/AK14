# AK14 — What happens to your photos (read this to the participant)

AK14 is a research prototype that turns the photos from one of your events into a few Instagram carousel options. Here is what happens to your photos:

**On this Mac:**
- We copy the photos from one event, which you choose, onto this Mac.
- AK14 looks at them here: dates, faces (it does not recognize who anyone is), sharpness and scenes. It picks a shortlist and builds the carousels here too.

**What leaves this Mac:**
- Small, low-resolution copies (160–384 px) of up to about 100 of the shortlisted photos, plus short text notes about them: time within the event, number of faces, scene labels.
- These go to OpenAI's API (model gpt-6-luna) only to choose and arrange photos for your carousel.
- Your original photos, GPS coordinates and file names are never sent.
- OpenAI does not train on API data by default. It may keep it for up to 30 days for abuse monitoring.

**What we record:**
- A code for you (for example P07), never your name.
- Which option you chose, the edits you made (reorder, swap, remove, reshuffle), whether you exported or shared it, and your answers at a short check-in after a week (whether you posted it). We don't store links to your posts.

**Deletion:** you can ask us to delete your photos and everything AK14 made from them at any time. Otherwise we delete them when the study ends.

Do you agree to continue? (The operator then answers the `ak14 run` prompt.)
