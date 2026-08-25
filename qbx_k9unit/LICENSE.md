# Licence and redistribution terms

**qbx_k9unit — Built by John Allday.**

Copyright © John Allday. All rights reserved.

---

## The short version

**This is not open source.** You may use it on your own server. You may not
give it away, sell it, publish it, or pass it on to anyone else.

If you only read one section, read that one. The rest of this document says
the same thing in more detail, and covers the questions people usually ask.

---

## What you are allowed to do

- **Run it** on the FiveM server or servers covered by your licence.
- **Change it** for your own use — edit the config, adjust the code, restyle
  the tablet, add your own ped models. It is your server; make it fit.
- **Keep backups** of it, including your modified version.
- **Let your own staff work on it** — developers you employ or trust to
  administer your server may access and edit the files as part of running it
  for you.

## What you are not allowed to do

- **Redistribute it.** Do not upload it anywhere public or private, do not
  put it in a GitHub repository, do not post it on a forum, a Discord, a
  leak site, a script marketplace, or a file host.
- **Resell it, sublicense it, or give it away**, whether or not you charge
  money and whether or not you changed it first.
- **Share it with another server owner**, including a friend, including
  "just to try it".
- **Publish it as your own work**, in whole or in part, modified or not.
- **Strip the authorship.** Do not remove or alter the author credit in
  `fxmanifest.lua` or this file.

**Modifying it does not make it yours.** A changed copy, a renamed copy, a
partial copy, or a copy with the credits removed is still covered by these
terms.

---

## Questions people actually ask

**Can I use this on more than one server?**
Only if your licence covers those servers. If you are not sure, ask before
you do it.

**Can I hire a developer to work on it?**
Yes. Someone working on your server, for you, may access the files. They may
not keep a copy for themselves or use it elsewhere afterwards.

**Can I share a snippet when asking for help?**
A few lines to explain a problem is fine. Posting whole files is not.

**Can I use ideas from it in my own script?**
Ideas are not owned. The code is. Do not copy the code.

**What if someone leaks it?**
That does not put it in the public domain and does not make it free to use.
Anyone running a leaked copy is using it without a licence, whether or not
they know where it came from.

**What if I stop using it?**
Delete your copies. See `sql/rollback/README.md` if you also want to remove
its database tables — that is written to be safe to run at any time.

---

## Third-party components

This resource depends on other software, which stays under its own licence
and is **not** covered by this document:

- **qbx_core, ox_lib, ox_target, ox_inventory, oxmysql** — required
  dependencies. They are not included here and remain under their own terms.
- **Audio files** in `html/sounds/` — sourced from third parties under their
  own licences, with attribution recorded in `html/sounds/CREDITS.md`.
  **That file is legally load-bearing: do not edit or delete it**, and do
  not remove the credits it contains. If you replace the audio with your
  own, record what you replaced it with.

Nothing in this document grants you any rights over those components, and
nothing in it takes away rights their own licences give you.

---

## No warranty

This resource is provided as-is. It comes with no guarantee that it is free
of defects, that it will suit your server, or that it will keep working
after an update to FiveM, Qbox, or any dependency.

Running it is at your own risk. Take backups. The database tooling in
`sql/rollback/` exists precisely so you can back up before you install and
remove it cleanly afterwards, and it is tested to be safe to re-run.

To the fullest extent the law allows, the author is not liable for any loss
or damage arising from its use — including lost data, server downtime, or
lost revenue.

---

## Contact

Questions about what this licence permits, requests for additional server
coverage, or reports of redistribution should go to John Allday.

---

*This document sets out the terms of use. Where it is unclear, the
restriction is intended to apply — ask rather than assume.*
