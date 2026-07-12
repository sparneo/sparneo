# Contribuer à Sparneo

Merci de l'intérêt que tu portes au projet ! Sparneo est un tracker de patrimoine
**privé et local-first** : les contributions qui renforcent cette promesse
(confidentialité, robustesse des données, ergonomie sobre) sont les bienvenues.

## Signaler un bug ou proposer une amélioration

Ouvre une **issue** sur le dépôt. Pour un bug, décris les étapes de
reproduction, le comportement attendu et le comportement observé, ainsi que ta
plateforme (Android, Linux desktop…). Aucune donnée personnelle ou financière
réelle n'est nécessaire pour reproduire un problème — n'en joins jamais.

## Proposer du code

1. Forke le dépôt et crée une branche dédiée (`feat/…` ou `fix/…`).
2. Respecte le style du code existant (commentaires en français, conventions
   du fichier voisin).
3. Avant d'ouvrir la pull request, assure-toi que :
   - `flutter analyze` ne remonte **aucune** erreur ;
   - `flutter test` passe **intégralement** ;
   - toute correction de bug ou nouvelle logique est **couverte par un test**.
4. Garde la PR focalisée sur un seul sujet ; explique le *pourquoi*, pas
   seulement le *quoi*.

## Licence des contributions

Le projet est distribué sous licence **GNU AGPL-3.0** (voir [`LICENSE`](LICENSE)).

**En soumettant une contribution** (pull request, correctif, ou tout autre
apport), tu acceptes qu'elle soit distribuée sous les termes de cette même
licence AGPL-3.0 — c'est le principe *inbound = outbound* : ce qui entre est
sous la même licence que ce qui sort. Tu certifies par ailleurs détenir les
droits nécessaires pour soumettre ta contribution sous cette licence (code que
tu as écrit, ou dont la licence d'origine est compatible et correctement
attribuée).

Il n'y a **pas de CLA** (accord de licence de contributeur) à signer : tu
conserves le droit d'auteur sur ton travail, et il reste sous AGPL-3.0 comme le
reste du projet.

---

# Contributing to Sparneo (English)

Thanks for your interest! Sparneo is a **private, local-first** wealth tracker;
contributions that strengthen that promise (privacy, data robustness, a clean UX)
are welcome.

## Reporting a bug or requesting a feature

Open an **issue** on the repository. For bugs, include reproduction steps,
expected vs. observed behaviour, and your platform (Android, Linux desktop…).
No real personal or financial data is ever needed to reproduce an issue — never
attach any.

## Contributing code

1. Fork the repo and create a dedicated branch (`feat/…` or `fix/…`).
2. Match the surrounding code style (comments are written in French, following
   each file's conventions).
3. Before opening the pull request, make sure that:
   - `flutter analyze` reports **no** errors;
   - `flutter test` passes **in full**;
   - any bug fix or new logic is **covered by a test**.
4. Keep the PR focused on a single topic; explain the *why*, not just the *what*.

## Licensing of contributions

The project is distributed under the **GNU AGPL-3.0** license (see
[`LICENSE`](LICENSE)).

**By submitting a contribution** (pull request, patch, or any other material),
you agree that it will be distributed under the terms of that same AGPL-3.0
license — this is the *inbound = outbound* principle: what comes in carries the
same license as what goes out. You also certify that you have the rights
necessary to submit your contribution under this license (code you wrote
yourself, or whose original license is compatible and properly attributed).

There is **no CLA** (Contributor License Agreement) to sign: you keep the
copyright on your work, and it stays under AGPL-3.0 like the rest of the project.
