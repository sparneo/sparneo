// lib/widgets/transaction_edit_dialog.dart
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/utils/formatters.dart';

/// Parse une chaîne décimale en [Decimal] EXACT (tolère la virgule FR et les
/// espaces parasites). Renvoie `null` si absente / vide / non-parsable — ce
/// `null` sert de signal « donnée insuffisante » dans [computeAmount].
///
/// IMPORTANT : ce champ [amount] est le PIVOT DU CASH (projection `Σ amount`,
/// cf. position_projection.dart). Il est calculé en [Decimal] EXACT — jamais
/// en `double` — pour la même hygiène arithmétique que le rejeu du journal :
/// une dérive binaire (`0.1 + 0.2`) ici fausserait le solde espèces dérivé.
Decimal? _decOrNull(String? s) {
  if (s == null) return null;
  final t = s.replaceAll(',', '.').trim();
  if (t.isEmpty) return null;
  return Decimal.tryParse(t);
}

/// Calcule le montant signé d'une transaction selon la convention du ledger :
///   - négatif pour buy / withdrawal (sortie de cash)
///   - positif pour sell / dividend / deposit / interest (entrée de cash)
///   - charge : signe PRÉSERVÉ tel que saisi (typiquement négatif ; positif
///     pour un rebate) — le moteur cash somme sans réinterpréter le signe.
///
/// Pour buy/sell : `|amount| = quantity × unitPrice ∓ fee` (fee augmente le
/// coût à l'achat, diminue le produit à la vente). Pour dividend, IDEM si
/// quantity/unitPrice sont fournis, SINON [rawAmount] fait foi (net encaissé
/// directement saisi — les relevés ne donnent pas toujours q×p, cf. design
/// §4). Pour deposit/withdrawal/interest/charge : le montant dérive
/// TOUJOURS du champ [rawAmount].
///
/// DEVISES CROISÉES (design §8) : quand [settlementAmount] est fourni (règlement
/// ≠ cotation — ex. titre USD dans un compte EUR), c'est LUI qui devient
/// `amount` (dans la devise de RÈGLEMENT), avec le SEUL signe dicté par le kind.
/// q×p/fee restent en cotation (titre/PRU) et ne composent PLUS `amount` :
/// l'identité `|amount| = q×p ∓ fee` (§6.1) n'a de sens qu'à devises ÉGALES
/// (règlement == cotation) ; en croisé (EUR − USD) elle est dimensionnellement
/// absurde. Le net réglé fait foi (valeur du relevé courtier).
///
/// Arithmétique EXACTE en [Decimal] (le champ [amount] est le pivot du cash ;
/// aucun calcul `double` ici — cf. [_decOrNull]). Renvoie null si les données
/// sont insuffisantes pour calculer.
String? computeAmount({
  required TransactionKind kind,
  String? quantity,
  String? unitPrice,
  String? fee,
  String? rawAmount,
  String? settlementAmount,
}) {
  // Devises croisées : le net réglé (devise du compte) prime sur q×p. Seul le
  // signe reste dicté par le kind (charge : signe déjà appliqué en amont par
  // l'UI, préservé). Aucune composition avec q×p/fee (cf. doc ci-dessus, §6.1).
  final settled = _decOrNull(settlementAmount);
  if (settled != null) {
    switch (kind) {
      case TransactionKind.buy:
      case TransactionKind.withdrawal:
        return (-settled.abs()).toString();
      case TransactionKind.sell:
      case TransactionKind.dividend:
      case TransactionKind.deposit:
      case TransactionKind.interest:
        return settled.abs().toString();
      case TransactionKind.charge:
        return settled.toString();
      case TransactionKind.openingBalance:
      case TransactionKind.adjustment:
        return null;
    }
  }

  final feeVal = _decOrNull(fee) ?? Decimal.zero;

  switch (kind) {
    case TransactionKind.buy:
      final q = _decOrNull(quantity);
      final p = _decOrNull(unitPrice);
      if (q == null || p == null) return null;
      // buy : sortie de cash (négatif). fee augmente le coût.
      return (-(q * p + feeVal)).toString();

    case TransactionKind.sell:
      final q = _decOrNull(quantity);
      final p = _decOrNull(unitPrice);
      if (q == null || p == null) return null;
      // sell : entrée de cash (positif). fee diminue le produit.
      return (q * p - feeVal).toString();

    case TransactionKind.dividend:
      final q = _decOrNull(quantity);
      final p = _decOrNull(unitPrice);
      if (q != null && p != null) {
        // Chemin q×p (relevé détaillant quantité + prix unitaire) : entrée de
        // cash (positif). fee diminue le produit.
        return (q * p - feeVal).toString();
      }
      // Chemin MONTANT (relevé ne donnant qu'un net encaissé, cas courant en
      // pratique) : q/p optionnels, on prend le montant saisi tel quel. Le
      // dividende est toujours une entrée de cash → force le signe positif
      // (comme deposit/interest), fee non applicable ici (déjà net).
      final a = _decOrNull(rawAmount);
      if (a == null) return null;
      return a.abs().toString();

    case TransactionKind.deposit:
      final a = _decOrNull(rawAmount);
      if (a == null) return null;
      // deposit : entrée de cash (positif, quelle que soit la saisie).
      return a.abs().toString();

    case TransactionKind.interest:
      final a = _decOrNull(rawAmount);
      if (a == null) return null;
      // interest : revenu d'espèces, toujours une entrée (positif).
      return a.abs().toString();

    case TransactionKind.withdrawal:
      final a = _decOrNull(rawAmount);
      if (a == null) return null;
      // withdrawal : sortie de cash (négatif, quelle que soit la saisie).
      return (-a.abs()).toString();

    case TransactionKind.charge:
      final a = _decOrNull(rawAmount);
      if (a == null) return null;
      // charge : signe PRÉSERVÉ (typiquement <0 ; rebate >0). Contrairement à
      // withdrawal, on ne force PAS le signe — une charge peut être un rebate.
      // La saisie du signe (négatif par défaut / positif pour un rebate) relève
      // de la couche UI (lot suivant).
      return a.toString();

    case TransactionKind.openingBalance:
    case TransactionKind.adjustment:
      // Mouvements système : non créés via ce dialogue. La sémantique de leur
      // montant relève du flux B* cœur ; ici on ne calcule rien (montant
      // préservé tel quel côté appelant).
      return null;
  }
}

/// Dialog Material 3 de création / édition d'une [AssetTransaction].
///
/// Usage :
/// ```dart
/// final tx = await showDialog<AssetTransaction>(
///   context: context,
///   builder: (_) => TransactionEditDialog(
///     accountId: 'acc1',
///     symbol: 'AAPL',
///     currency: 'EUR',
///   ),
/// );
/// if (tx != null) await storage.upsert(tx);
/// ```
///
/// En mode édition, passer [existing] ; le dialog réutilise son [id].
/// Retourne null si l'utilisateur annule.
class TransactionEditDialog extends StatefulWidget {
  final String accountId;
  final String? symbol;

  /// Devise de COTATION de l'actif (quantity/unitPrice/fee) — celle affichée sur
  /// les champs titres et comparée au cours Yahoo pour le PRU.
  final String currency;

  /// Devise de RÈGLEMENT = devise DU COMPTE (celle de `amount`, effet net sur
  /// les espèces). `null` = non fournie → comportement mono-devise legacy
  /// (règlement supposé identique à la cotation). Quand elle DIFFÈRE de
  /// [currency] (ex. titre USD dans un compte EUR), le dialogue exige un champ
  /// « Montant net réglé (devise du compte) » qui devient `amount`, et pose
  /// `settlementCurrency` sur la transaction émise (design cash-ledger §8).
  final String? settlementCurrency;

  /// Service de change pour l'ASSIST FX (préremplissage éditable du net réglé).
  /// Optionnel : `null` → le singleton [ExchangeRateService] est utilisé (résolu
  /// en [initState], pour garder le constructeur `const`). Injectable en test.
  final ExchangeRateService? exchangeRateService;

  final AssetTransaction? existing;

  /// Kind pré-sélectionné à l'ouverture en mode CRÉATION (ignoré en édition, où
  /// le kind de [existing] prévaut). Sert notamment au nudge fiscal « Enregistrer
  /// une vente » qui ouvre ce dialogue pré-réglé sur [TransactionKind.sell].
  /// Un kind système ([TransactionKind.isSystemGenerated]) est ignoré : ces
  /// mouvements ne se créent pas via ce dialogue.
  final TransactionKind? initialKind;

  /// Restreint les kinds proposés par le sélecteur de type. `null` (défaut) =
  /// comportement historique (tous les kinds non-système). Sert à cadrer ce
  /// dialogue selon son point d'ouverture — ex. une fiche position ne propose
  /// que {buy, sell, dividend, charge} (un « Dépôt » n'a pas de sens rattaché à
  /// un titre), le journal du compte propose {deposit, withdrawal, interest,
  /// charge} (mouvements d'espèces purs). Comme pour l'exclusion des kinds
  /// système, le kind COURANT reste valide en ÉDITION même s'il est hors liste
  /// (ex. un vieux `deposit` legacy tamponné d'un symbol) : on ne veut jamais
  /// bloquer l'édition d'une ligne existante.
  final Set<TransactionKind>? allowedKinds;

  const TransactionEditDialog({
    super.key,
    required this.accountId,
    this.symbol,
    required this.currency,
    this.settlementCurrency,
    this.exchangeRateService,
    this.existing,
    this.initialKind,
    this.allowedKinds,
  });

  @override
  State<TransactionEditDialog> createState() => _TransactionEditDialogState();
}

class _TransactionEditDialogState extends State<TransactionEditDialog> {
  final _formKey = GlobalKey<FormState>();

  late TransactionKind _kind;
  late DateTime _date;
  late TextEditingController _quantityCtrl;
  late TextEditingController _unitPriceCtrl;
  late TextEditingController _feeCtrl;
  late TextEditingController _noteCtrl;
  /// Montant brut saisi directement : cash pur (deposit/withdrawal/interest/
  /// charge) OU dividend saisi en montant (q/p absents, cf. [computeAmount]).
  late TextEditingController _rawAmountCtrl;

  /// Montant NET RÉGLÉ dans la devise du COMPTE (devise de règlement), affiché
  /// UNIQUEMENT en devises croisées ([_isCrossCurrency]). Fait autorité sur
  /// `amount` (design §8). Préremplissable via l'assist FX (éditable).
  late TextEditingController _netSettledCtrl;

  /// Vrai dès que l'utilisateur a touché [_netSettledCtrl] : gèle l'assist FX
  /// (on ne réécrase jamais une valeur saisie / confirmée à la main).
  bool _netEditedByUser = false;

  /// Service de change effectif (injecté en test, singleton sinon).
  late final ExchangeRateService _fx;

  /// Signe de `charge` (frais autonome) : la saisie ([_rawAmountCtrl]) reste
  /// une MAGNITUDE (jamais de signe demandé à l'utilisateur, comme pour
  /// deposit/withdrawal) ; ce booléen porte le signe. `false` = frais
  /// (négatif, valeur par défaut) ; `true` = remboursement/rebate (positif).
  bool _chargeIsRebate = false;

  /// Devises croisées : règlement (compte) ≠ cotation (actif). Déclenche le
  /// champ « Montant net réglé » et l'émission de `settlementCurrency`.
  bool get _isCrossCurrency =>
      widget.settlementCurrency != null &&
      widget.settlementCurrency!.trim().isNotEmpty &&
      widget.settlementCurrency!.toUpperCase() != widget.currency.toUpperCase();

  @override
  void initState() {
    super.initState();
    _fx = widget.exchangeRateService ?? ExchangeRateService();
    final e = widget.existing;
    // Priorité : kind du mouvement édité > initialKind fourni (hors kinds
    // système, jamais créés ici, ET dans allowedKinds si restreint) > premier
    // kind autorisé si [allowedKinds] est fourni (ex. journal du compte, où
    // `buy` n'aurait pas de sens comme défaut) > buy par défaut sinon.
    final preset = widget.initialKind;
    final allowed = widget.allowedKinds;
    final presetValid = preset != null &&
        !preset.isSystemGenerated &&
        (allowed == null || allowed.contains(preset));
    final fallbackKind =
        (allowed != null && allowed.isNotEmpty) ? allowed.first : TransactionKind.buy;
    _kind = e?.kind ?? (presetValid ? preset : fallbackKind);
    _date = e?.date ?? DateTime.now();
    _quantityCtrl = TextEditingController(text: e?.quantity ?? '');
    _unitPriceCtrl = TextEditingController(text: e?.unitPrice ?? '');
    _feeCtrl = TextEditingController(text: e?.fee ?? '');
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    // Pré-remplissage du montant brut : cash pur (deposit/withdrawal/interest/
    // charge) OU dividend déjà saisi en montant (amount présent sans q/p).
    final prefillRaw = e?.amount != null &&
        (_isCashOnly(e!.kind) ||
            (e.kind == TransactionKind.dividend &&
                (e.quantity == null || e.unitPrice == null)));
    if (prefillRaw) {
      final a = double.tryParse(e.amount!);
      _rawAmountCtrl = TextEditingController(
        text: a != null ? a.abs().toString() : '',
      );
    } else {
      _rawAmountCtrl = TextEditingController();
    }
    // charge existant : le signe DU MONTANT STOCKÉ pilote le toggle (positif
    // = rebate). Sans effet pour les autres kinds (reste au défaut = frais).
    _chargeIsRebate = e?.kind == TransactionKind.charge &&
        e?.amount != null &&
        (double.tryParse(e!.amount!) ?? -1) >= 0;

    // Champ « net réglé » (devise du compte) : en ÉDITION d'une ligne croisée,
    // le montant est déjà figé dans `amount` (devise de règlement) → préremplir
    // sa magnitude et geler l'assist FX (ne jamais réécraser un fait passé). En
    // CRÉATION, laisser vide : l'assist FX proposera une valeur au fil de la
    // saisie q×p (cf. [_maybePrefillNet]).
    _netSettledCtrl = TextEditingController();
    if (_isCrossCurrency && e?.amount != null) {
      final a = double.tryParse(e!.amount!);
      if (a != null) {
        _netSettledCtrl.text = a.abs().toString();
        _netEditedByUser = true;
      }
    }
    // Création en devises croisées : tenter un préremplissage FX différé (après
    // le premier frame, le temps que d'éventuelles données q×p soient là — en
    // pratique l'utilisateur les saisit ensuite, ce qui redéclenche l'assist).
    if (_isCrossCurrency && e == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrefillNet());
    }
  }

  @override
  void dispose() {
    _quantityCtrl.dispose();
    _unitPriceCtrl.dispose();
    _feeCtrl.dispose();
    _noteCtrl.dispose();
    _rawAmountCtrl.dispose();
    _netSettledCtrl.dispose();
    super.dispose();
  }

  /// Vrai si [d] est proche d'aujourd'hui (± 1 jour calendaire) : l'assist FX
  /// n'utilise QUE le taux COURANT (design §8). Une date passée ne doit PAS être
  /// convertie au taux du jour (le taux historique = amélioration ultérieure) —
  /// on laisse alors le champ vide pour une saisie manuelle du net réglé.
  bool _isNearToday(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    return today.difference(day).inDays.abs() <= 1;
  }

  /// ASSIST FX (préremplissage éditable du net réglé, devise du compte).
  ///
  /// Ne fait rien hors devises croisées, si l'utilisateur a déjà touché le
  /// champ, ou si la date n'est pas proche d'aujourd'hui. Base = |montant en
  /// COTATION| (q×p ∓ fee via [computeAmount] mono-devise) × taux courant. Le
  /// [ExchangeRateService] ne sait convertir QUE vers EUR ([getRateToEur]) :
  /// pour une devise de règlement autre qu'EUR, on n'assiste pas (champ laissé
  /// vide, saisie manuelle). La valeur proposée est une SUGGESTION éditable — le
  /// montant qui fait foi est celui confirmé dans le champ (reparsé en [Decimal]
  /// à la soumission) ; le produit `double` du taux ne sert qu'à l'affichage.
  Future<void> _maybePrefillNet() async {
    if (!_isCrossCurrency || _netEditedByUser) return;
    if (!_isNearToday(_date)) return;
    if (widget.settlementCurrency!.toUpperCase() != 'EUR') return;

    // Montant en devise de cotation (magnitude), s'il est calculable.
    final quote = computeAmount(
      kind: _kind,
      quantity: _quantityCtrl.text,
      unitPrice: _unitPriceCtrl.text,
      fee: _feeCtrl.text,
      rawAmount: _effectiveRawAmount(),
    );
    final quoteDec = _decOrNull(quote);
    if (quoteDec == null) return; // q×p (ou montant) pas encore saisi

    final rate = await _fx.getRateToEur(widget.currency);
    if (!mounted || _netEditedByUser) return;
    final converted = quoteDec.abs().toDouble() * rate;
    setState(() {
      _netSettledCtrl.text = converted.toStringAsFixed(2);
    });
  }

  /// Convention de signe `charge` appliquée au NET RÉGLÉ (comme
  /// [_effectiveRawAmount] pour le champ montant brut) : le champ porte une
  /// MAGNITUDE, le signe vient du toggle [_chargeIsRebate]. Sans effet pour les
  /// autres kinds (le signe est appliqué par [computeAmount]).
  String _effectiveNetSettled() {
    if (_kind != TransactionKind.charge) return _netSettledCtrl.text;
    final magnitude =
        _netSettledCtrl.text.trim().replaceFirst(RegExp(r'^[+-]\s*'), '');
    return _chargeIsRebate ? magnitude : '-$magnitude';
  }

  /// Kinds en MONTANT PUR (pas de quantité/prix, pas de frais séparé) :
  /// deposit/withdrawal (apport/retrait) + interest/charge (lot cash-ledger —
  /// mouvements en montant, pas q/p, cf. design §4).
  bool _isCashOnly(TransactionKind k) =>
      k == TransactionKind.deposit ||
      k == TransactionKind.withdrawal ||
      k == TransactionKind.interest ||
      k == TransactionKind.charge;

  /// Convention de signe `charge` : [_rawAmountCtrl] porte une MAGNITUDE
  /// (jamais de signe demandé à l'utilisateur, comme deposit/withdrawal) ; le
  /// signe vient du toggle [_chargeIsRebate]. Un éventuel signe déjà tapé par
  /// l'utilisateur est écarté avant d'appliquer celui du toggle. Sans effet
  /// pour les autres kinds (texte du champ inchangé).
  String _effectiveRawAmount() {
    if (_kind != TransactionKind.charge) return _rawAmountCtrl.text;
    final magnitude =
        _rawAmountCtrl.text.trim().replaceFirst(RegExp(r'^[+-]\s*'), '');
    return _chargeIsRebate ? magnitude : '-$magnitude';
  }

  /// Calcule `amount` (devise de RÈGLEMENT) depuis l'état courant. En devises
  /// croisées, le NET RÉGLÉ fait autorité ([settlementAmount]) ; sinon calcul
  /// mono-devise classique (q×p / montant brut).
  String? _computeCurrentAmount() {
    return computeAmount(
      kind: _kind,
      quantity: _quantityCtrl.text.trim(),
      unitPrice: _unitPriceCtrl.text.trim(),
      fee: _feeCtrl.text.trim(),
      rawAmount: _effectiveRawAmount().trim(),
      settlementAmount:
          _isCrossCurrency ? _effectiveNetSettled().trim() : null,
    );
  }

  /// Devise dans laquelle s'exprime `amount` (règlement) — celle du compte en
  /// croisé, sinon la cotation. Sert au symbole du récapitulatif.
  String get _settlementDisplayCurrency =>
      _isCrossCurrency ? widget.settlementCurrency! : widget.currency;

  /// Calcule l'amount en live pour l'afficher en récapitulatif.
  String _previewAmount() => _computeCurrentAmount() ?? '—';

  /// onChanged des champs de COTATION (quantité / prix / frais) : rafraîchit le
  /// récapitulatif ET retente l'assist FX (le net réglé dérive de q×p).
  void _onQuoteFieldChanged() {
    setState(() {});
    _maybePrefillNet();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final amount = _computeCurrentAmount();

    // dividend : q/p et rawAmount sont TOUS DEUX optionnels côté validateurs
    // de champ (l'un OU l'autre suffit) — la garde effective (« au moins un
    // chemin complet ») se fait ici, sur le résultat de computeAmount, plutôt
    // que par une validation croisée entre champs.
    if (_kind == TransactionKind.dividend && amount == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.invalidAmount)),
      );
      return;
    }

    // Ceinture-bretelles sur le symbole émis : un mouvement d'espèces pur n'a
    // JAMAIS de symbole, même si ce dialogue a été ouvert depuis une fiche
    // titre (widget.symbol non-null) — ex. un « Dépôt » saisi depuis une
    // position ne doit pas sortir `symbol=AI.PA` (cf. doc modèle
    // asset_transaction.dart + spec export fiscal : symbol null pour un
    // mouvement d'espèces). `charge` reste hybride et suit widget.symbol (frais
    // adossé à une ligne titre depuis la fiche position, frais de compte
    // autonome depuis le journal où widget.symbol est déjà null). Les autres
    // kinds (buy/sell/dividend/système) conservent le comportement historique.
    final symbol = (_kind == TransactionKind.deposit ||
            _kind == TransactionKind.withdrawal ||
            _kind == TransactionKind.interest)
        ? null
        : widget.symbol;

    final tx = AssetTransaction(
      id: widget.existing?.id ?? AssetTransaction.generateId(),
      accountId: widget.accountId,
      symbol: symbol,
      kind: _kind,
      quantity:
          _isCashOnly(_kind) ? null : _nvl(_quantityCtrl.text),
      unitPrice:
          _isCashOnly(_kind) ? null : _nvl(_unitPriceCtrl.text),
      amount: amount,
      currency: widget.currency,
      // Devise de RÈGLEMENT : posée UNIQUEMENT en devises croisées (règlement ≠
      // cotation) — `amount` est alors dans la devise du compte. En mono-devise,
      // on laisse null (règlement == cotation) pour ne pas polluer les backups
      // (le moteur retombe sur `currency`, cf. position_projection.dart).
      settlementCurrency:
          _isCrossCurrency ? widget.settlementCurrency : null,
      date: _date,
      // fee : sans objet pour les kinds en montant pur (deposit/withdrawal/
      // interest/charge — le champ n'est même pas affiché pour eux, cf.
      // build()) ; null explicite pour ne jamais polluer la ligne (design §4 :
      // « le champ fee reste null sur une ligne charge »).
      fee: _isCashOnly(_kind) ? null : _nvl(_feeCtrl.text),
      note: _nvl(_noteCtrl.text),
    );

    Navigator.of(context).pop(tx);
  }

  /// Convertit un champ texte vide en null, trim sinon.
  String? _nvl(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
      // La date pilote l'assist FX (taux courant seulement) : retenter après
      // changement (ne fait rien si l'utilisateur a déjà saisi le net réglé).
      _maybePrefillNet();
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  String _kindLabel(AppLocalizations l10n, TransactionKind k) {
    switch (k) {
      case TransactionKind.buy:
        return l10n.transactionKindBuy;
      case TransactionKind.sell:
        return l10n.transactionKindSell;
      case TransactionKind.dividend:
        return l10n.transactionKindDividend;
      case TransactionKind.deposit:
        return l10n.transactionKindDeposit;
      case TransactionKind.withdrawal:
        return l10n.transactionKindWithdrawal;
      case TransactionKind.openingBalance:
        return l10n.transactionKindOpeningBalance;
      case TransactionKind.adjustment:
        return l10n.transactionKindAdjustment;
      case TransactionKind.interest:
        return l10n.transactionKindInterest;
      case TransactionKind.charge:
        return l10n.transactionKindCharge;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cashOnly = _isCashOnly(_kind);
    // dividend : q/p ET montant sont tous deux affichés, tous deux
    // optionnels au niveau champ (cf. §4 design) — la garde « au moins un
    // chemin complet » est faite dans [_submit], pas ici.
    final isDividend = _kind == TransactionKind.dividend;
    final crossCurrency = _isCrossCurrency;
    // En devises croisées, le champ « net réglé » (devise du compte) REMPLACE le
    // champ montant brut : ce dernier serait dans la devise de cotation et ferait
    // doublon avec le net réglé qui, lui, fait autorité sur `amount` (design §8).
    final showRawAmount = (cashOnly || isDividend) && !crossCurrency;

    return AlertDialog(
      title: Text(
        widget.existing == null ? l10n.addTransaction : l10n.editTransactionTitle,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---- Kind ----
                DropdownButtonFormField<TransactionKind>(
                  initialValue: _kind,
                  decoration: InputDecoration(
                    labelText: l10n.detailType,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  // Les kinds système ne sont pas proposés à la création ; on
                  // garde toutefois le kind courant s'il en est un (édition
                  // d'un mouvement importé) pour que la valeur reste valide.
                  // Idem pour [allowedKinds] : filtre le sélecteur selon le
                  // point d'ouverture du dialogue, sans jamais invalider le
                  // kind courant en édition (même logique d'exception).
                  items: TransactionKind.values
                      .where((k) => !k.isSystemGenerated || k == _kind)
                      .where((k) =>
                          widget.allowedKinds == null ||
                          widget.allowedKinds!.contains(k) ||
                          k == _kind)
                      .map((k) {
                    return DropdownMenuItem(
                      value: k,
                      child: Text(_kindLabel(l10n, k)),
                    );
                  }).toList(),
                  onChanged: (k) {
                    if (k != null) setState(() => _kind = k);
                  },
                ),
                const SizedBox(height: 12),

                // ---- Date ----
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.transactionDate,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: const Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(_formatDate(_date)),
                  ),
                ),
                const SizedBox(height: 12),

                // ---- Champs titres (masqués pour deposit/withdrawal) ----
                if (!cashOnly) ...[
                  TextFormField(
                    controller: _quantityCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.transactionQuantity,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      // dividend : quantité optionnelle, saisie en montant
                      // possible (cf. §4 design).
                      helperText: (_kind.isSystemGenerated || isDividend)
                          ? l10n.optionalHint
                          : null,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    onChanged: (_) => _onQuoteFieldChanged(),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) {
                        if (isDividend) return null; // saisie en montant
                        return l10n.invalidQuantity;
                      }
                      if (double.tryParse(t.replaceAll(',', '.')) == null) {
                        return l10n.invalidValue;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _unitPriceCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.transactionUnitPrice,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      helperText: (_kind.isSystemGenerated || isDividend)
                          ? l10n.optionalHint
                          : null,
                      suffixText: Formatters.formatCurrencySymbol(
                          widget.currency),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    onChanged: (_) => _onQuoteFieldChanged(),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) {
                        // PRU facultatif pour les mouvements système
                        // (position initiale déclarative / ajustement
                        // d'inventaire) et pour dividend (saisie en montant,
                        // cf. §4). Requis pour les opérations de marché
                        // (buy/sell).
                        if (_kind.isSystemGenerated || isDividend) return null;
                        return l10n.invalidValue;
                      }
                      if (double.tryParse(t.replaceAll(',', '.')) == null) {
                        return l10n.invalidValue;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],

                // ---- Montant brut (deposit/withdrawal/interest/charge, et
                // dividend saisi en montant plutôt qu'en q×p) — masqué en
                // devises croisées (remplacé par le champ « net réglé »). ----
                if (showRawAmount) ...[
                  TextFormField(
                    controller: _rawAmountCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.transactionAmount,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      // dividend : le montant est optionnel SI quantité + prix
                      // sont fournis (chemin q×p classique) — la garde
                      // effective est faite à la soumission.
                      helperText: isDividend ? l10n.dividendAmountHint : null,
                      suffixText: Formatters.formatCurrencySymbol(
                          widget.currency),
                    ),
                    keyboardType: TextInputType.numberWithOptions(
                        decimal: true,
                        // dividend : saisie possiblement négative interdite
                        // (montant net) mais on autorise le signe au clavier
                        // par simplicité ; charge : signe géré par le toggle
                        // ci-dessous, la saisie reste une magnitude (pas de
                        // touche « - » nécessaire).
                        signed: _kind != TransactionKind.charge),
                    onChanged: (_) => setState(() {}),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) {
                        // dividend : validé à la soumission (cf. _submit),
                        // pas ici — l'alternative q×p peut suffire.
                        if (isDividend) return null;
                        return l10n.invalidAmount;
                      }
                      if (double.tryParse(t.replaceAll(',', '.')) == null) {
                        return l10n.invalidValue;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],

                // ---- Signe de charge (frais par défaut, rebate possible) ----
                if (_kind == TransactionKind.charge) ...[
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: Text(l10n.chargeSignFeeLabel),
                          selected: !_chargeIsRebate,
                          onSelected: (_) =>
                              setState(() => _chargeIsRebate = false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          label: Text(l10n.chargeSignRebateLabel),
                          selected: _chargeIsRebate,
                          onSelected: (_) =>
                              setState(() => _chargeIsRebate = true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Nudge préventif fiscal : un frais de courtage saisi ici
                  // (charge) plutôt que dans le champ `fee` d'un buy/sell
                  // laisse le cash juste (le montant charge est bien compté)
                  // mais SOUS-ÉVALUE le PRU — seul le champ fee d'un
                  // achat/vente entre dans le prix de revient (cf.
                  // computeAmount). Résultat : plus-value surévaluée à
                  // l'export fiscal. Erreur silencieuse (aucune validation ne
                  // la détecte), d'où ce rappel statique. Affiché uniquement
                  // en contexte position (widget.symbol non-null) : depuis le
                  // journal du compte (symbol == null), il n'existe pas
                  // d'ordre auquel rattacher le frais, le cas ne se pose pas.
                  if (widget.symbol != null) ...[
                    Text(
                      l10n.chargeOrderFeeHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],

                // ---- Frais (sans objet pour les mouvements en montant pur :
                // deposit/withdrawal/interest/charge, cf. design §4) ----
                if (!cashOnly) ...[
                  TextFormField(
                    controller: _feeCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.transactionFee,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixText: Formatters.formatCurrencySymbol(
                          widget.currency),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    onChanged: (_) => _onQuoteFieldChanged(),
                  ),
                  const SizedBox(height: 12),
                ],

                // ---- Montant net réglé (devise du COMPTE) — devises croisées
                // uniquement. OBLIGATOIRE : c'est LUI qui devient `amount` (la
                // valeur du relevé courtier fait foi, design §8). Préremplissable
                // via l'assist FX (taux courant, éditable). ----
                if (crossCurrency) ...[
                  TextFormField(
                    controller: _netSettledCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.settlementAmountLabel(
                          widget.settlementCurrency!),
                      helperText: l10n.settlementAmountHint,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixText: Formatters.formatCurrencySymbol(
                          widget.settlementCurrency!),
                    ),
                    keyboardType: TextInputType.numberWithOptions(
                        decimal: true,
                        // charge : signe géré par le toggle (magnitude saisie) ;
                        // autres kinds : signe imposé par le kind.
                        signed: _kind != TransactionKind.charge),
                    onChanged: (_) {
                      _netEditedByUser = true;
                      setState(() {});
                    },
                    validator: (v) {
                      final t = (v ?? '').trim().replaceAll(',', '.');
                      // Magnitude nue possible pour charge (le signe vient du
                      // toggle) ; on valide juste la présence d'un décimal.
                      final magnitude =
                          t.replaceFirst(RegExp(r'^[+-]\s*'), '');
                      if (magnitude.isEmpty) return l10n.invalidAmount;
                      if (Decimal.tryParse(magnitude) == null) {
                        return l10n.invalidValue;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],

                // ---- Note ----
                TextFormField(
                  controller: _noteCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.transactionNote,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),

                // ---- Récapitulatif montant (lecture seule) ----
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.transactionAmount,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        // `amount` s'exprime dans la devise de RÈGLEMENT (compte
                        // en croisé, sinon cotation) — cf. [_settlementDisplayCurrency].
                        '${_previewAmount()} ${Formatters.formatCurrencySymbol(_settlementDisplayCurrency)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.save),
        ),
      ],
      actionsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }
}
