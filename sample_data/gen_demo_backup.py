#!/usr/bin/env python3
"""Générateur du jeu de démonstration Sparneo (sample_data/demo-backup.json).

Garantit par construction la cohérence journal → projection :
- quantité/PRU de chaque position = rejeu WAC exact du journal (miroir de
  replayLedger, arithmétique Fraction) ;
- solde espèces dérivé = Σ amount (devise de règlement), jamais négatif en
  cours de route pour les comptes où c'est irréaliste (PEA/CTO/AV/crypto).
"""
import json
import math
import os
from fractions import Fraction
from datetime import date, datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Cours actuels (Yahoo, 2026-07-09) — calibrage des valeurs
# ---------------------------------------------------------------------------
LIVE = {
    'WPEA.PA': 6.884, 'ESE.PA': 33.29, 'PAEEM.PA': 36.065, 'CW8.PA': 682.28,
    'TTE.PA': 68.67, 'MC.PA': 491.05, 'AAPL': 311.43, '4GLD.DE': 115.92,
    'EUNA.DE': 4.9098, 'LI.PA': 35.78, 'BTC-EUR': 54968.72, 'ETH-EUR': 1521.76,
}
USD_EUR = 0.8716
GOLD_EUR_PER_G = 4136.4 / 31.1034768 * USD_EUR  # ~115.9 €/g

F = Fraction

def d(iso, hh=10, mm=0):
    return f"{iso}T{hh:02d}:{mm:02d}:00.000"

# ---------------------------------------------------------------------------
# Journal — définition déclarative
# tx = (date, symbol, kind, qty, unitPrice, amount, currency, settlement, fee, note, meta)
# ---------------------------------------------------------------------------

def tx(date_, kind, symbol=None, qty=None, price=None, amount=None,
       currency='EUR', settlement=None, fee=None, note=None, meta=None, hh=10):
    return {
        'date': d(date_, hh), 'kind': kind, 'symbol': symbol, 'qty': qty,
        'price': price, 'amount': amount, 'currency': currency,
        'settlement': settlement, 'fee': fee, 'note': note, 'meta': meta,
    }

def fmt(x):
    """Format décimal canonique sans zéros superflus."""
    if x is None:
        return None
    if isinstance(x, Fraction):
        x = float(x)
    s = f"{x:.6f}".rstrip('0').rstrip('.')
    return s if s not in ('', '-0') else '0'

def buy_amount(qty, price, fee=0, rate=1.0):
    """Effet net signé sur les espèces d'un achat (devise de règlement)."""
    return -round((qty * price + fee) * rate, 2)

def sell_amount(qty, price, fee=0, rate=1.0):
    return round((qty * price - fee) * rate, 2)

ACCOUNTS = [
    # (id, name, kind, currency, description, createdAt, cashBalance)
    ('a-pea',    'PEA',              'pea',           'EUR', 'ETF capitalisants + actions européennes',  '2023-01-20T09:00:00.000', None),
    ('a-av',     'Assurance-vie',    'assuranceVie',  'EUR', 'Contrat multisupports (fonds euros + UC)', '2023-02-06T09:00:00.000', None),
    ('a-livret', 'Livret A',         'cash',          'EUR', 'Épargne de précaution',                    '2023-03-01T09:00:00.000', 8350.0),
    ('a-metal',  'Or physique',      'preciousMetal', 'EUR', 'Pièces et lingotins au coffre',            '2023-05-01T09:00:00.000', None),
    ('a-cto',    'Compte-titres',    'cto',           'EUR', None,                                       '2023-09-01T09:00:00.000', None),
    ('a-crypto', 'Crypto',           'crypto',        'EUR', None,                                       '2024-02-01T09:00:00.000', None),
]

JOURNAL = {}

# --- Assurance-vie -----------------------------------------------------------
JOURNAL['a-av'] = [
    tx('2023-02-06', 'openingBalance', amount=3800,
       note='Fonds en euros — solde à la reprise du contrat',
       meta={'declarative': True}, hh=9),
    tx('2023-02-06', 'openingBalance', symbol='CW8.PA', qty=12, price=495,
       note='Unités de compte à la reprise du contrat',
       meta={'declarative': True}, hh=9, currency='EUR'),
    tx('2024-01-03', 'interest', amount=95.30, note='Intérêts 2023 — fonds en euros'),
    tx('2024-12-31', 'charge', amount=-34.50, note='Frais de gestion UC 2024'),
    tx('2025-01-03', 'interest', amount=101.10, note='Intérêts 2024 — fonds en euros'),
    tx('2025-06-16', 'buy', symbol='CW8.PA', qty=2, price=641.50,
       amount=buy_amount(2, 641.50), note='Arbitrage fonds euros → UC'),
    tx('2025-12-31', 'charge', amount=-36.20, note='Frais de gestion UC 2025'),
    tx('2026-01-05', 'interest', amount=108.40, note='Intérêts 2025 — fonds en euros'),
]

# --- PEA ----------------------------------------------------------------------
_pea = []
_pea.append(tx('2023-02-01', 'deposit', amount=3000, note='Versement initial'))
_pea.append(tx('2023-02-06', 'buy', symbol='ESE.PA', qty=80, price=19.50,
               amount=buy_amount(80, 19.50, 2), fee=2))
_pea.append(tx('2023-07-10', 'deposit', amount=1500))
_pea.append(tx('2023-07-12', 'buy', symbol='TTE.PA', qty=25, price=59.30,
               amount=buy_amount(25, 59.30, 3), fee=3))
_pea.append(tx('2023-07-17', 'buy', symbol='ESE.PA', qty=60, price=21.05,
               amount=buy_amount(60, 21.05, 2), fee=2))
_pea.append(tx('2024-01-08', 'deposit', amount=2000))
_pea.append(tx('2024-01-10', 'buy', symbol='ESE.PA', qty=50, price=23.40,
               amount=buy_amount(50, 23.40, 2), fee=2))
_pea.append(tx('2024-01-16', 'dividend', symbol='TTE.PA', qty=25, price=0.74,
               amount=18.50, note='Acompte sur dividende'))
_pea.append(tx('2024-06-10', 'deposit', amount=2400))
_pea.append(tx('2024-06-12', 'buy', symbol='WPEA.PA', qty=300, price=5.05,
               amount=buy_amount(300, 5.05, 1.5), fee=1.5))
_pea.append(tx('2024-06-17', 'buy', symbol='ESE.PA', qty=40, price=25.60,
               amount=buy_amount(40, 25.60, 2), fee=2))
_pea.append(tx('2024-07-01', 'dividend', symbol='TTE.PA', qty=25, price=0.79,
               amount=19.75, note='Acompte sur dividende'))
_pea.append(tx('2024-11-12', 'deposit', amount=1500))
_pea.append(tx('2024-11-14', 'buy', symbol='WPEA.PA', qty=250, price=5.45,
               amount=buy_amount(250, 5.45, 1.5), fee=1.5))
_pea.append(tx('2024-11-18', 'buy', symbol='PAEEM.PA', qty=30, price=31.80,
               amount=buy_amount(30, 31.80, 1.5), fee=1.5))
_pea.append(tx('2025-01-14', 'dividend', symbol='TTE.PA', qty=25, price=0.81,
               amount=20.25, note='Acompte sur dividende'))
_pea.append(tx('2025-03-10', 'deposit', amount=2000))
_pea.append(tx('2025-03-12', 'buy', symbol='ESE.PA', qty=50, price=28.50,
               amount=buy_amount(50, 28.50, 2), fee=2))
_pea.append(tx('2025-03-17', 'buy', symbol='WPEA.PA', qty=100, price=5.62,
               amount=buy_amount(100, 5.62, 1.5), fee=1.5))
_pea.append(tx('2025-06-24', 'dividend', symbol='TTE.PA', qty=25, price=0.82,
               amount=20.50, note='Acompte sur dividende'))
_pea.append(tx('2025-09-08', 'deposit', amount=1500))
_pea.append(tx('2025-09-10', 'buy', symbol='WPEA.PA', qty=250, price=6.08,
               amount=buy_amount(250, 6.08, 1.5), fee=1.5))
_pea.append(tx('2026-01-12', 'deposit', amount=2000))
_pea.append(tx('2026-01-13', 'dividend', symbol='TTE.PA', qty=25, price=0.84,
               amount=21.00, note='Acompte sur dividende'))
_pea.append(tx('2026-01-14', 'buy', symbol='WPEA.PA', qty=150, price=6.45,
               amount=buy_amount(150, 6.45, 1.5), fee=1.5))
_pea.append(tx('2026-01-19', 'buy', symbol='PAEEM.PA', qty=25, price=33.50,
               amount=buy_amount(25, 33.50, 1.5), fee=1.5))
_pea.append(tx('2026-02-10', 'sell', symbol='ESE.PA', qty=20, price=32.40,
               amount=sell_amount(20, 32.40, 2), fee=2,
               note='Allègement — rééquilibrage vers le monde'))
_pea.append(tx('2026-04-07', 'deposit', amount=1200))
_pea.append(tx('2026-04-08', 'buy', symbol='WPEA.PA', qty=150, price=6.20,
               amount=buy_amount(150, 6.20, 1.5), fee=1.5))
_pea.append(tx('2026-06-23', 'dividend', symbol='TTE.PA', qty=25, price=0.85,
               amount=21.25, note='Acompte sur dividende'))
JOURNAL['a-pea'] = _pea

# --- CTO ----------------------------------------------------------------------
# AAPL coté USD, réglé EUR (settlementCurrency) : le taux de change est un fait
# passé figé dans amount (relevé courtier).
_cto = []
_cto.append(tx('2023-09-04', 'deposit', amount=3000, note='Versement initial'))
_cto.append(tx('2023-09-15', 'buy', symbol='AAPL', qty=5, price=178.50,
               amount=buy_amount(5, 178.50, 4.5, rate=0.935), currency='USD',
               settlement='EUR', fee=4.5))
_cto.append(tx('2024-04-08', 'deposit', amount=2000))
_cto.append(tx('2024-04-10', 'buy', symbol='MC.PA', qty=2, price=692.00,
               amount=buy_amount(2, 692.00, 5), fee=5))
_cto.append(tx('2024-04-12', 'buy', symbol='4GLD.DE', qty=10, price=72.40,
               amount=buy_amount(10, 72.40, 4), fee=4))
_cto.append(tx('2024-05-16', 'dividend', symbol='AAPL', qty=5, price=0.25,
               amount=round(5 * 0.25 * 0.92, 2), currency='USD', settlement='EUR'))
_cto.append(tx('2024-11-17', 'deposit', amount=1500))
_cto.append(tx('2024-11-20', 'buy', symbol='LI.PA', qty=40, price=24.80,
               amount=buy_amount(40, 24.80, 3), fee=3))
_cto.append(tx('2024-12-05', 'buy', symbol='AAPL', qty=3, price=225.00,
               amount=buy_amount(3, 225.00, 3, rate=0.95), currency='USD',
               settlement='EUR', fee=3))
_cto.append(tx('2025-01-02', 'charge', amount=-12.00, note='Droits de garde 2024'))
_cto.append(tx('2025-02-13', 'dividend', symbol='AAPL', qty=8, price=0.25,
               amount=round(8 * 0.25 * 0.96, 2), currency='USD', settlement='EUR'))
_cto.append(tx('2025-04-15', 'buy', symbol='MC.PA', qty=1, price=538.00,
               amount=buy_amount(1, 538.00, 3), fee=3,
               note='Renforcement après correction'))
_cto.append(tx('2025-05-06', 'dividend', symbol='LI.PA', qty=40, price=1.20,
               amount=48.00))
_cto.append(tx('2025-06-23', 'deposit', amount=1500))
_cto.append(tx('2025-06-25', 'buy', symbol='EUNA.DE', qty=320, price=4.735,
               amount=buy_amount(320, 4.735, 4), fee=4,
               note='Poche obligataire'))
_cto.append(tx('2025-06-27', 'buy', symbol='4GLD.DE', qty=8, price=85.10,
               amount=buy_amount(8, 85.10, 4), fee=4))
_cto.append(tx('2025-11-13', 'dividend', symbol='AAPL', qty=8, price=0.26,
               amount=round(8 * 0.26 * 0.87, 2), currency='USD', settlement='EUR'))
_cto.append(tx('2025-12-04', 'dividend', symbol='MC.PA', qty=3, price=5.50,
               amount=16.50, note='Acompte sur dividende'))
_cto.append(tx('2026-01-05', 'charge', amount=-12.00, note='Droits de garde 2025'))
_cto.append(tx('2026-02-02', 'deposit', amount=1000))
_cto.append(tx('2026-04-23', 'dividend', symbol='MC.PA', qty=3, price=7.50,
               amount=22.50, note='Solde du dividende'))
_cto.append(tx('2026-05-12', 'dividend', symbol='LI.PA', qty=40, price=1.30,
               amount=52.00))
_cto.append(tx('2026-05-14', 'dividend', symbol='AAPL', qty=8, price=0.26,
               amount=round(8 * 0.26 * 0.875, 2), currency='USD', settlement='EUR'))
JOURNAL['a-cto'] = _cto

# --- Crypto -------------------------------------------------------------------
_cry = []
_cry.append(tx('2024-02-05', 'deposit', amount=3500, note='Versement initial'))
_cry.append(tx('2024-02-12', 'buy', symbol='BTC-EUR', qty=0.03, price=36200,
               amount=buy_amount(0.03, 36200, 10.90), fee=10.90))
_cry.append(tx('2024-03-05', 'buy', symbol='ETH-EUR', qty=0.8, price=2905,
               amount=buy_amount(0.8, 2905, 23.20), fee=23.20))
_cry.append(tx('2024-08-18', 'deposit', amount=1200))
_cry.append(tx('2024-08-20', 'buy', symbol='BTC-EUR', qty=0.022, price=41800,
               amount=buy_amount(0.022, 41800, 9.20), fee=9.20))
_cry.append(tx('2024-12-16', 'deposit', amount=1300))
_cry.append(tx('2024-12-18', 'buy', symbol='ETH-EUR', qty=0.5, price=2410,
               amount=buy_amount(0.5, 2410, 12.00), fee=12.00))
_cry.append(tx('2025-06-10', 'adjustment', symbol='ETH-EUR', qty=0.006,
               note='Récompenses de staking (inventaire)'))
_cry.append(tx('2025-11-14', 'sell', symbol='ETH-EUR', qty=0.2, price=1880,
               amount=sell_amount(0.2, 1880, 3.80), fee=3.80,
               note='Vente partielle'))
_cry.append(tx('2025-11-20', 'withdrawal', amount=-700,
               note='Retrait vers compte courant'))
_cry.append(tx('2026-01-10', 'charge', amount=-4.90,
               note='Frais de tenue de compte plateforme'))
_cry.append(tx('2026-03-02', 'adjustment', amount=0.53,
               note="Régularisation d'arrondi plateforme"))
JOURNAL['a-crypto'] = _cry

# --- Or physique (aucun mouvement d'espèces : achats réglés hors compte) ------
JOURNAL['a-metal'] = [
    tx('2023-05-10', 'openingBalance', symbol='NAPOLEON-20-FRANCS', qty=2,
       price=478, note='Pièces héritées', meta={'declarative': True}),
    tx('2024-10-08', 'buy', symbol='NAPOLEON-20-FRANCS', qty=2, price=585,
       fee=12, note='Achat comptoir — prime 5,5 %'),
    tx('2025-02-14', 'buy', symbol='LINGOTIN-10-G', qty=1, price=985,
       note='Achat comptoir'),
]

# Livret A : compte cash à solde manuel, pas de journal.
JOURNAL['a-livret'] = []

# ---------------------------------------------------------------------------
# Actifs (métadonnées des positions)
# ---------------------------------------------------------------------------
ASSETS = {
    'WPEA.PA': {'symbol': 'WPEA.PA', 'name': 'iShares MSCI World Swap PEA UCITS ETF',
                'type': 'etf', 'currency': 'EUR', 'exchange': 'PAR'},
    'ESE.PA': {'symbol': 'ESE.PA', 'name': 'BNP Paribas Easy S&P 500 UCITS ETF',
               'type': 'etf', 'currency': 'EUR', 'exchange': 'PAR'},
    'PAEEM.PA': {'symbol': 'PAEEM.PA', 'name': 'Amundi PEA MSCI Emerging Markets ETF',
                 'type': 'etf', 'currency': 'EUR', 'exchange': 'PAR'},
    'TTE.PA': {'symbol': 'TTE.PA', 'name': 'TotalEnergies SE',
               'type': 'stock', 'currency': 'EUR', 'exchange': 'PAR'},
    'CW8.PA': {'symbol': 'CW8.PA', 'name': 'Amundi MSCI World UCITS ETF',
               'type': 'etf', 'currency': 'EUR', 'exchange': 'PAR'},
    'AAPL': {'symbol': 'AAPL', 'name': 'Apple Inc.',
             'type': 'stock', 'currency': 'USD', 'exchange': 'NMS'},
    'MC.PA': {'symbol': 'MC.PA', 'name': 'LVMH Moët Hennessy Louis Vuitton',
              'type': 'stock', 'currency': 'EUR', 'exchange': 'PAR'},
    # Overrides manuels du type (typeLocked) : ETC or et ETF obligataire —
    # jamais auto-détectables (Yahoo les renvoie EQUITY/ETF).
    '4GLD.DE': {'symbol': '4GLD.DE', 'name': 'Xetra-Gold ETC',
                'type': 'preciousMetal', 'typeLocked': True,
                'currency': 'EUR', 'exchange': 'GER'},
    'EUNA.DE': {'symbol': 'EUNA.DE', 'name': 'iShares Core Global Aggregate Bond UCITS ETF',
                'type': 'bond', 'typeLocked': True,
                'currency': 'EUR', 'exchange': 'GER'},
    'LI.PA': {'symbol': 'LI.PA', 'name': 'Klépierre SA',
              'type': 'realEstate', 'typeLocked': True,
              'currency': 'EUR', 'exchange': 'PAR'},
    'BTC-EUR': {'symbol': 'BTC-EUR', 'name': 'Bitcoin',
                'type': 'crypto', 'currency': 'EUR'},
    'ETH-EUR': {'symbol': 'ETH-EUR', 'name': 'Ethereum',
                'type': 'crypto', 'currency': 'EUR'},
    # Métaux physiques : pricés via le cours de référence GC=F (USD/once),
    # poids fin × prime — cf. Asset.unitPriceFromSpot.
    'NAPOLEON-20-FRANCS': {'symbol': 'NAPOLEON-20-FRANCS', 'name': 'Napoléon 20 Francs',
                           'type': 'preciousMetal', 'typeLocked': True,
                           'currency': 'EUR', 'exchange': None,
                           'refSymbol': 'GC=F', 'refQuoteUnit': 'ounce',
                           'fineWeightGrams': 5.805, 'premiumPercent': 5.5},
    'LINGOTIN-10-G': {'symbol': 'LINGOTIN-10-G', 'name': 'Lingotin 10 g',
                      'type': 'preciousMetal', 'typeLocked': True,
                      'currency': 'EUR', 'exchange': None,
                      'refSymbol': 'GC=F', 'refQuoteUnit': 'ounce',
                      'fineWeightGrams': 10.0, 'premiumPercent': 3.0},
}
CUSTOM_NAMES = {'4GLD.DE': 'Or papier (ETC)'}

# ---------------------------------------------------------------------------
# Rejeu WAC (miroir exact de replayLedger, arithmétique Fraction)
# ---------------------------------------------------------------------------

def replay(txs):
    """Rejoue un journal trié → (qty: Fraction, cost: Fraction, cash: {cur: Fraction})."""
    qty, cost = F(0), F(0)
    cash = {}
    for t in sorted(txs, key=lambda t: t['date']):
        if t['amount'] is not None:
            cur = t['settlement'] or t['currency']
            cash[cur] = cash.get(cur, F(0)) + F(str(t['amount']))
        k = t['kind']
        q = F(str(t['qty'])) if t['qty'] is not None else F(0)
        p = F(str(t['price'])) if t['price'] is not None else F(0)
        fee = F(str(t['fee'])) if t['fee'] is not None else F(0)
        if k == 'buy':
            qty += q
            cost += q * p + fee
        elif k == 'sell':
            sold = F(0)
            if qty > 0:
                q_eff = min(q, qty)
                sold = cost * q_eff / qty
            qty = max(F(0), qty - q)
            cost = max(F(0), cost - sold)
        elif k == 'openingBalance':
            qty += q
            cost += q * p
        elif k == 'adjustment':
            qty = max(F(0), qty + q)
            cost = max(F(0), cost + q * p)
    return qty, cost, cash

def running_cash_ok(txs, currency):
    """Vérifie que le solde espèces (devise du compte) ne passe jamais < 0."""
    bal = F(0)
    for t in sorted(txs, key=lambda t: t['date']):
        if t['amount'] is not None and (t['settlement'] or t['currency']) == currency:
            bal += F(str(t['amount']))
            if bal < 0:
                return False, t['date'], float(bal)
    return True, None, float(bal)

# ---------------------------------------------------------------------------
# Construction du backup
# ---------------------------------------------------------------------------
positions = {}
transactions = {}
summary = {}

for acc_id, name, kind, currency, desc, created, cash_balance in ACCOUNTS:
    txs = JOURNAL[acc_id]
    # 1. journal sérialisé (ordre export : date ASC, id ASC)
    txs_sorted = sorted(txs, key=lambda t: t['date'])
    out_txs = []
    for i, t in enumerate(txs_sorted, 1):
        entry = {
            'id': f"t-{acc_id[2:]}-{i:03d}",
            'accountId': acc_id,
            'symbol': t['symbol'],
            'kind': t['kind'],
            'quantity': fmt(t['qty']),
            'unitPrice': fmt(t['price']),
            'amount': fmt(t['amount']),
            'currency': t['currency'],
        }
        if t['settlement']:
            entry['settlementCurrency'] = t['settlement']
        entry.update({
            'date': t['date'],
            'fee': fmt(t['fee']),
            'note': t['note'],
            'meta': t['meta'],
        })
        out_txs.append(entry)
    if out_txs:
        transactions[acc_id] = out_txs

    # 2. positions = projection du journal (cohérence par construction)
    symbols = sorted({t['symbol'] for t in txs if t['symbol']})
    pos_list = []
    acc_value = F(0)
    for sym in symbols:
        sym_txs = [t for t in txs if t['symbol'] == sym]
        qty, cost, _ = replay(sym_txs)
        pru = float(cost / qty) if qty > 0 and cost > 0 else None
        asset = dict(ASSETS[sym])
        pos = {
            'accountId': acc_id,
            'asset': {k: v for k, v in asset.items() if v is not None or k in ('name', 'exchange')},
            'quantity': str(qty.numerator) if qty.denominator == 1 else fmt(qty),
            'averageBuyPrice': round(pru, 6) if pru is not None else None,
        }
        if sym in CUSTOM_NAMES:
            pos['customName'] = CUSTOM_NAMES[sym]
        else:
            pos['customName'] = None
        pos_list.append(pos)
        # valeur estimée (calibrage)
        if sym in LIVE:
            unit = LIVE[sym] * (USD_EUR if asset['currency'] == 'USD' else 1)
        else:
            w = asset['fineWeightGrams']
            prem = asset['premiumPercent']
            unit = GOLD_EUR_PER_G * w * (1 + prem / 100)
        acc_value += F(str(round(float(qty) * unit, 2)))
    if pos_list:
        positions[acc_id] = pos_list

    # 3. cash dérivé + garde-fou de réalisme
    _, _, cash = replay(txs)
    derived = cash.get(currency, F(0))
    if acc_id in ('a-pea', 'a-cto', 'a-av', 'a-crypto'):
        ok, when, bal = running_cash_ok(txs, currency)
        assert ok, f"{acc_id}: solde espèces négatif ({bal}) au {when}"
        assert derived >= 0
    foreign = {c: float(v) for c, v in cash.items() if c != currency and v != 0}
    assert not foreign, f"{acc_id}: buckets devises étrangères non nuls {foreign}"

    total = float(acc_value + derived + F(str(cash_balance or 0)))
    summary[name] = {
        'titres': round(float(acc_value), 2),
        'especes': round(float(derived), 2) if txs else (cash_balance or 0),
        'total': round(total + (0 if not txs else 0), 2),
    }

# ---------------------------------------------------------------------------
# Snapshots : hebdomadaires (lundis) juil. 2024 → juil. 2026
# ---------------------------------------------------------------------------
ANCHORS = [
    (date(2024, 7, 8), 34500), (date(2024, 10, 7), 37800),
    (date(2024, 12, 30), 41200), (date(2025, 3, 3), 42600),
    (date(2025, 3, 31), 42100), (date(2025, 4, 7), 38200),   # correction
    (date(2025, 4, 28), 39900), (date(2025, 7, 7), 44300),
    (date(2025, 10, 6), 48700), (date(2025, 12, 29), 52600),
    (date(2026, 2, 9), 51100),                                 # repli
    (date(2026, 4, 6), 54200), (date(2026, 7, 6), 59600),
]

def interp(day):
    for (d0, v0), (d1, v1) in zip(ANCHORS, ANCHORS[1:]):
        if d0 <= day <= d1:
            f = (day - d0).days / max(1, (d1 - d0).days)
            return v0 + (v1 - v0) * f
    return ANCHORS[-1][1]

snapshots = []
day = ANCHORS[0][0]
while day <= ANCHORS[-1][0]:
    base = interp(day)
    # bruit déterministe ±1 % (aucun aléa : reproductible)
    o = day.toordinal()
    noise = 0.006 * math.sin(o / 4.1) + 0.004 * math.sin(o / 9.7 + 1.3)
    value = round(base * (1 + noise), 2)
    captured = int(datetime(day.year, day.month, day.day, 18, 0,
                            tzinfo=timezone.utc).timestamp() * 1000)
    snapshots.append({
        'date': day.isoformat(), 'totalValue': value, 'currency': 'EUR',
        'capturedAt': captured, 'accountCount': 6, 'schemaVersion': 1,
    })
    day += timedelta(days=7)

# ---------------------------------------------------------------------------
# Assemblage final
# ---------------------------------------------------------------------------
backup = {
    'format': 'sparneo_backup',
    'version': 3,
    'exportedAt': '2026-07-09T12:00:00.000',
    'data': {
        'wallets': [
            {'id': 'w-demo', 'name': 'Mon Patrimoine',
             'createdAt': '2023-01-10T09:00:00.000'},
        ],
        'accounts': [
            {'id': a[0], 'walletId': 'w-demo', 'name': a[1], 'kind': a[2],
             'currency': a[3], 'description': a[4], 'createdAt': a[5],
             'cashBalance': a[6]}
            for a in ACCOUNTS
        ],
        'positions': positions,
        'transactions': transactions,
        'snapshots': {'w-demo': snapshots},
        'allocationTargets': {
            'w-demo': {'targets': {
                'etf': 40.0, 'stock': 8.0, 'bond': 4.0, 'realEstate': 3.0,
                'preciousMetal': 10.0, 'crypto': 7.0, 'cash': 28.0,
            }},
        },
    },
}

# Sérialisation : structure indentée, entrées feuilles (position / transaction /
# snapshot) sur UNE ligne — même style que le fichier historique.
def dump_leaf(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(', ', ': '))

def dump(o, indent=0):
    pad = '  ' * indent
    if isinstance(o, dict):
        items = []
        for k, v in o.items():
            items.append(f'{pad}  "{k}": {dump_inner(v, indent + 1)}')
        return '{\n' + ',\n'.join(items) + f'\n{pad}}}'
    raise ValueError

def dump_inner(v, indent):
    pad = '  ' * indent
    if isinstance(v, dict):
        # feuille ? (aucune valeur conteneur de conteneurs)
        return dump(v, indent)
    if isinstance(v, list):
        if not v:
            return '[]'
        lines = ',\n'.join(f'{pad}  {dump_leaf(e)}' for e in v)
        return '[\n' + lines + f'\n{pad}]'
    return json.dumps(v, ensure_ascii=False)

out = dump(backup)
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'demo-backup.json')
with open(path, 'w', encoding='utf-8') as f:
    f.write(out + '\n')

# round-trip de contrôle
with open(path, encoding='utf-8') as f:
    json.load(f)

print(f"OK -> {path}")
print(f"{'Compte':<16}{'Titres':>12}{'Espèces':>12}{'Total':>12}")
grand = 0
for name, s in summary.items():
    print(f"{name:<16}{s['titres']:>12.2f}{s['especes']:>12.2f}{s['total']:>12.2f}")
    grand += s['total']
print(f"{'TOTAL':<16}{'':>12}{'':>12}{grand:>12.2f}")
print(f"Transactions: {sum(len(v) for v in transactions.values())}, "
      f"snapshots: {len(snapshots)}")
