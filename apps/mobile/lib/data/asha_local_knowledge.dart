import 'dart:math' as math;

/// Clinical knowledge category for assistive communication and acute care.
enum AshaKnowledgeCategory {
  alsMnd,
  strokeAphasia,
  seizureFirstAid,
  spinalCordInjury,
  deviceOperations,
  careRoutine,
  bilingualGuidance,
}

/// A structured knowledge document in Asha's embedded clinical repository.
class AshaKnowledgeDocument {
  const AshaKnowledgeDocument({
    required this.id,
    required this.title,
    required this.category,
    required this.keywords,
    required this.summary,
    required this.content,
    this.locale = 'en-US',
  });

  final String id;
  final String title;
  final AshaKnowledgeCategory category;
  final List<String> keywords;
  final String summary;
  final String content;
  final String locale;
}

/// Scored result from a local knowledge query.
class AshaLocalRetrievalResult {
  const AshaLocalRetrievalResult({
    required this.documentId,
    required this.title,
    required this.category,
    required this.snippet,
    required this.score,
  });

  final String documentId;
  final String title;
  final AshaKnowledgeCategory category;
  final String snippet;
  final double score;
}

const _kStopwords = {
  'a', 'about', 'above', 'after', 'again', 'against', 'all', 'am', 'an', 'and',
  'any', 'are', 'arent', 'as', 'at', 'be', 'because', 'been', 'before', 'being',
  'below', 'between', 'both', 'but', 'by', 'cant', 'cannot', 'could', 'couldnt',
  'did', 'didnt', 'do', 'does', 'doesnt', 'doing', 'dont', 'down', 'during',
  'each', 'few', 'for', 'from', 'further', 'had', 'hadnt', 'has', 'hasnt',
  'have', 'havent', 'having', 'he', 'hed', 'hell', 'hes', 'her', 'here',
  'hers', 'herself', 'him', 'himself', 'his', 'how', 'i', 'im', 'id', 'ill',
  'if', 'in', 'into', 'is', 'isnt', 'it', 'its', 'itself', 'lets', 'me',
  'more', 'most', 'mustnt', 'my', 'myself', 'no', 'nor', 'not', 'of', 'off',
  'on', 'once', 'only', 'or', 'other', 'ought', 'our', 'ours', 'ourselves',
  'out', 'over', 'own', 'same', 'shant', 'she', 'shed', 'shell', 'shes',
  'should', 'shouldnt', 'so', 'some', 'such', 'than', 'that', 'thats',
  'the', 'their', 'theirs', 'them', 'themselves', 'then', 'there', 'theres',
  'these', 'they', 'theyd', 'theyll', 'theyre', 'theyve', 'this', 'those',
  'through', 'to', 'too', 'under', 'until', 'up', 'very', 'was', 'wasnt',
  'we', 'wed', 'well', 'were', 'werent', 'what', 'whats', 'when', 'where',
  'which', 'while', 'who', 'whom', 'why', 'with', 'wont', 'would', 'wouldnt',
  'you', 'youd', 'youll', 'youre', 'youve', 'your', 'yours', 'yourself',
};

const Map<String, List<String>> _kSynonyms = {
  'জল': ['water', 'hydration'],
  'পানি': ['water', 'hydration'],
  'thirsty': ['hydration', 'drinking', 'water', 'thirst'],
  'thirst': ['hydration', 'drinking', 'water'],
  'drink': ['water', 'hydration', 'dysphagia', 'swallow'],
  'swallowing': ['dysphagia', 'choking', 'aspiration', 'water'],
  'swallow': ['dysphagia', 'choking', 'aspiration', 'water'],
  'কাঁপুনি': ['seizure', 'convulsion'],
  'খিঁচুনি': ['seizure', 'convulsion'],
  'seizure': ['convulsion', 'airway', 'recovery', 'first aid'],
  'convulsion': ['seizure', 'cushion', 'recovery', 'airway'],
  'choking': ['airway', 'obstruction', 'distress', 'breathing', 'cough'],
  'choke': ['airway', 'obstruction', 'distress', 'breathing', 'cough'],
  'breathe': ['airway', 'respiration', 'choking', 'distress'],
  'breathing': ['airway', 'respiration', 'choking', 'distress'],
  'dysreflexia': ['autonomic', 'hypertension', 'blood pressure', 'headache', 'spinal'],
  'headache': ['dysreflexia', 'blood pressure', 'hypertension', 'catheter'],
  'fatigue': ['als', 'mnd', 'micro-gesture', 'dwell', 'pacing', 'weakness'],
  'tired': ['fatigue', 'als', 'energy', 'dwell', 'rest'],
  'weak': ['fatigue', 'als', 'energy', 'dwell', 'rest'],
  'cramp': ['als', 'fatigue', 'fasciculation', 'spasm', 'rest'],
  'tremor': ['dwell', 'sensitivity', 'als', 'pacing'],
  'battery': ['charging', 'telemetry', 'wheelchair', 'pi', 'power'],
  'screen': ['caption', 'wheelchair', 'display', 'lcd'],
  'display': ['caption', 'wheelchair', 'screen', 'lcd'],
  'reposition': ['pressure', 'sore', 'injury', 'turning', 'bed'],
  'turning': ['pressure', 'sore', 'reposition', 'skin'],
};

/// Embedded clinical documents for NeuroBridge Asha.
const List<AshaKnowledgeDocument> kClinicalKnowledgeDocuments = [
  AshaKnowledgeDocument(
    id: 'als-mnd-01',
    title: 'ALS & Motor Neuron Disease AAC Communication & Energy Conservation',
    category: AshaKnowledgeCategory.alsMnd,
    keywords: [
      'als', 'amyotrophic', 'lateral', 'sclerosis', 'mnd', 'motor neuron',
      'fatigue', 'bulbar', 'micro-gesture', 'dwell', 'energy', 'weakness', 'tremor'
    ],
    summary: 'Guidance on micro-gestures, pacing, and fatigue management for progressive motor neuron disease.',
    content: 'In progressive motor neuron disease (ALS/MND), voluntary motor unit recruitment diminishes, '
        'often leading to rapid muscular fatigue during repeated movements. For patients using micro-gestures:\n'
        '1. Pacing & Dwell: Maintain dwell thresholds between 500ms and 750ms to prevent accidental triggers while '
        'avoiding prolonged isometric contraction that causes rapid tremor or exhaustion.\n'
        '2. Low-Effort Resting States: Calibrate gestures with hand resting comfortably on a tray, armrest, or lap. '
        'Do not require unsupported anti-gravity hand holding.\n'
        '3. Energy Conservation: Schedule frequent low-stimulation rest intervals. If muscular twitching or fatigue occurs, '
        'switch to secondary access modes such as single-switch scanning or eye-gaze blinking.\n'
        '4. Core Essentials: Prioritize urgent phrases (Water, Help, Nurse, Pain, Reposition) at the top of the '
        'vocabulary lattice to minimize physical effort for vital biological needs.',
  ),
  AshaKnowledgeDocument(
    id: 'stroke-aphasia-01',
    title: 'Stroke Recovery, Expressive Aphasia & Multi-Modal Communication',
    category: AshaKnowledgeCategory.strokeAphasia,
    keywords: [
      'stroke', 'aphasia', 'hemiparesis', 'expressive', 'infarct', 'paralysis',
      'one-handed', 'confirmation', 'frustration', 'speech'
    ],
    summary: 'Communication scaffolding and confirmation techniques for stroke survivors with hemiparesis or expressive aphasia.',
    content: 'Post-stroke patients frequently experience unilateral hemiparesis paired with expressive aphasia. '
        'Effective communication scaffolding requires:\n'
        '1. Single-Hand Unilateral Tracking: Configure NeuroBridge for unilateral dominant or non-paretic hand tracking. '
        'Ensure the unaffected hand has clean visual contrast against clothing or bed linen.\n'
        '2. Binary Confirmation Grids: When word-retrieval difficulty occurs, provide clear binary yes/no confirmation '
        'rather than open-ended queries. Give at least 5-8 seconds processing time before prompting again.\n'
        '3. Emotional Validation: Expressive aphasia frequently triggers profound frustration. Keep Asha spoken feedback '
        'concise, encouraging, and dignified. Affirm understanding with visual cues on the companion screen.\n'
        '4. Positioning: Support the affected limb in a neutral anatomical position with pillows to prevent subluxation '
        'and spasticity while using the communicative hand.',
  ),
  AshaKnowledgeDocument(
    id: 'seizure-triage-01',
    title: 'Clinical Seizure First Aid & Acute Triage Protocol',
    category: AshaKnowledgeCategory.seizureFirstAid,
    keywords: [
      'seizure', 'convulsion', 'epilepsy', 'tonic-clonic', 'fit', 'shaking',
      'jerking', 'first aid', 'airway', 'recovery position', 'emergency'
    ],
    summary: 'Evidence-based acute seizure safety, positioning, timing, and caregiver escalation rules.',
    content: 'Acute seizure first aid protocol for patients with neuromuscular vulnerability:\n'
        '1. Immediate Safety: Clear hard, sharp, or hot objects from the bedside or wheelchair perimeter. Cushion the head '
        'with soft fabric or an inflated air cushion.\n'
        '2. Airway Protection: Do NOT insert fingers, tongue depressors, or spoons into the patient mouth. Do NOT restrain '
        'tonic or clonic limb movements.\n'
        '3. Post-Ictal Recovery: Once convulsive shaking ceases, gently roll patient onto their side into the recovery '
        'position to maintain a patent airway and prevent aspiration of saliva or vomitus.\n'
        '4. Time the Event: Initiate Asha emergency timer immediately. If seizure duration exceeds 5 continuous minutes '
        '(status epilepticus), if breathing remains labored, or if trauma occurs, call Emergency Ambulance (911) immediately.',
  ),
  AshaKnowledgeDocument(
    id: 'sci-dysreflexia-01',
    title: 'Autonomic Dysreflexia Recognition & Urgent Intervention Protocol',
    category: AshaKnowledgeCategory.spinalCordInjury,
    keywords: [
      'autonomic', 'dysreflexia', 'spinal cord injury', 'sci', 't6', 'hypertension',
      'headache', 'sweating', 'flushing', 'catheter', 'bladder', 'bowel', 'emergency'
    ],
    summary: 'Life-saving protocol for recognizing and resolving autonomic dysreflexia in T6 or higher spinal cord injuries.',
    content: 'Autonomic Dysreflexia (AD) is a potentially life-threatening medical emergency affecting individuals '
        'with spinal cord injuries at or above T6 level:\n'
        '1. Clinical Signs: Sudden severe pounding headache, dangerously elevated blood pressure (20-40 mmHg above baseline), '
        'profuse sweating and skin blotching above lesion level, nasal congestion, and bradycardia.\n'
        '2. Immediate Action: Sit the patient completely UPRIGHT at 90 degrees immediately with legs dangling if feasible. '
        'Never lay the patient flat, as upright positioning produces orthostatic pooling and reduces cranial arterial pressure.\n'
        '3. Remove Noxious Stimuli: Loosen all tight clothing, belts, abdominal binders, and shoe laces. Rapidly inspect '
        'urinary drainage: unkink tubing, empty full leg bags, or irrigate clogged indwelling catheters. Check for fecal impaction.\n'
        '4. Medical Escalation: If systolic BP remains elevated (>150 mmHg) after 10 minutes or cause cannot be identified, '
        'summon emergency medical services immediately for pharmacological intervention.',
  ),
  AshaKnowledgeDocument(
    id: 'care-dysphagia-01',
    title: 'Bedside Hydration, Swallowing Safety & Dysphagia Aspiration Protocol',
    category: AshaKnowledgeCategory.careRoutine,
    keywords: [
      'hydration', 'water', 'drink', 'drinking', 'thirst', 'swallowing',
      'dysphagia', 'aspiration', 'choking', 'straw', 'chin tuck', 'fluid'
    ],
    summary: 'Clinical guidelines for safe fluid intake, preventing aspiration pneumonia in bulbar-impaired patients.',
    content: 'Patients with motor neuron disease or severe stroke often experience progressive bulbar dysphagia. '
        'Guidelines for safe bedside hydration:\n'
        '1. Upright Posture: Patient must be seated at 90 degrees with head in neutral or slight chin-tuck posture. '
        'Never administer fluids while reclined or lying down.\n'
        '2. Fluid Consistency & Delivery: Use prescribed fluid viscosity (thin, nectar-thick, or honey-thick). '
        'For weak oral seal, use a short, wide-bore flexible silicone straw or valved drinking cup rather than standard straws.\n'
        '3. Small Bolus Size: Limit fluid mouthfuls to 5-10 mL. Ensure patient swallows twice per sip before offering more.\n'
        '4. Aspiration Alert Signs: Wet gurgly vocal quality, coughing during or immediately after drinking, watering eyes, '
        'or red face indicate silent or overt aspiration. Stop fluid intake immediately and notify caregiver.',
  ),
  AshaKnowledgeDocument(
    id: 'pressure-injury-01',
    title: 'Wheelchair Pressure Relief & Repositioning Schedule',
    category: AshaKnowledgeCategory.careRoutine,
    keywords: [
      'pressure', 'reposition', 'turning', 'bed sore', 'ulcer', 'ischemia',
      'cushion', 'wheelchair', 'redness', 'tilt'
    ],
    summary: 'Standard clinical protocols for preventing pressure ulcers through timed weight shifts and skin inspection.',
    content: 'Immobile patients in wheelchairs or bedside beds are at extreme risk of ischemic pressure injuries over '
        'bony prominences (ischial tuberosities, sacrum, heels, trochanters):\n'
        '1. Frequency: Wheelchair weight shifts must occur every 15-30 minutes for at least 1-2 minutes. Bed repositioning '
        'must occur at least every 2 hours.\n'
        '2. Power Tilt & Recline: If using power wheelchair seating, achieve at least 30-45 degrees tilt combined with '
        'recline to effectively offload sacral and ischial pressures.\n'
        '3. Skin Inspection: Report any non-blanching erythema (persistent redness), warmth, or skin breakdown immediately.\n'
        '4. Automated Scheduling: Asha maintains an internal 2-hour care routine timer to alert caregivers when repositioning is due.',
  ),
  AshaKnowledgeDocument(
    id: 'device-telemetry-01',
    title: 'Wheelchair Pi Companion Display & Telemetry Operations',
    category: AshaKnowledgeCategory.deviceOperations,
    keywords: [
      'raspberry pi', 'wheelchair', 'display', 'screen', 'lcd', 'battery',
      'telemetry', 'camera', 'hardware', 'companion', 'caption'
    ],
    summary: 'Operational protocols for companion LCD display broadcasting, camera health, and battery telemetry monitoring.',
    content: 'The NeuroBridge Asha assistive hardware suite comprises a bedside/wheelchair companion screen and local sensor hub:\n'
        '1. Screen Captions: Any patient phrase or caregiver reassurance can be mirrored instantly to the outward-facing LCD screen '
        'so visitors, medical staff, and family can read messages without looking over the patient shoulder.\n'
        '2. Power Management: Battery telemetry reports separate percentages for the mobile phone and wheelchair auxiliary battery. '
        'When battery drops below 20%, Asha sounds a spoken low-power advisory.\n'
        '3. Fail-Safe Offline Mode: The system communicates via direct UDP beacons and local HTTP without internet connectivity.',
  ),
  AshaKnowledgeDocument(
    id: 'bilingual-bengali-01',
    title: 'Bilingual AAC Guidance (Bengali & English Communication)',
    category: AshaKnowledgeCategory.bilingualGuidance,
    keywords: [
      'bilingual', 'bengali', 'bangla', 'বাংলা', 'জল', 'পানি', 'সাহায্য',
      'ডাক্তার', 'ব্যথা', 'language', 'locale', 'translation'
    ],
    summary: 'Culturally and linguistically tailored AAC mapping for South Asian and bilingual patients.',
    content: 'NeuroBridge Asha provides native bilingual speech and gesture recognition in English and Bengali:\n'
        '1. Vital Words: বাংলা ভাষায় জরুরি সংকেতসমূহ: জল/পানি (Water), সাহায্য (Help), ব্যথা (Pain), ওষুধ (Medicine), '
        'বিশ্রাম (Rest), ডাক্তার (Doctor)।\n'
        '2. Culturally Respectful Tone: Spoken responses maintain dignified, respectful phrasing addressing the patient '
        'with warmth and calm reassurance.\n'
        '3. Dual-Language Display: Messages can be presented simultaneously in Bengali script and English translations on '
        'the companion LCD screen.',
  ),
];

/// Fast client-side hybrid TF-IDF & keyword retriever.
class AshaLocalKnowledgeRetriever {
  AshaLocalKnowledgeRetriever({
    List<AshaKnowledgeDocument>? documents,
  }) : _documents = documents ?? kClinicalKnowledgeDocuments {
    _buildIndex();
  }

  final List<AshaKnowledgeDocument> _documents;
  final List<List<String>> _docTokens = [];
  final Map<String, int> _docFreqs = {};
  final List<Map<String, double>> _docVectors = [];
  final List<double> _docNorms = [];

  void _buildIndex() {
    _docTokens.clear();
    _docFreqs.clear();
    _docVectors.clear();
    _docNorms.clear();

    final numDocs = _documents.length;
    if (numDocs == 0) return;

    for (final doc in _documents) {
      final fullText = '${doc.title} ${doc.keywords.join(' ')} ${doc.summary} ${doc.content}';
      final tokens = tokenize(fullText);
      _docTokens.add(tokens);
      final uniqueTokens = tokens.toSet();
      for (final tok in uniqueTokens) {
        _docFreqs[tok] = (_docFreqs[tok] ?? 0) + 1;
      }
    }

    for (final tokens in _docTokens) {
      final counts = <String, int>{};
      for (final t in tokens) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
      final totalTerms = math.max(tokens.length, 1);
      final vector = <String, double>{};
      var normSq = 0.0;
      counts.forEach((term, count) {
        final tf = count / totalTerms;
        final idf = math.log((numDocs + 1) / ((_docFreqs[term] ?? 0) + 1)) + 1.0;
        final weight = tf * idf;
        vector[term] = weight;
        normSq += weight * weight;
      });
      _docVectors.add(vector);
      _docNorms.add(normSq > 0 ? math.sqrt(normSq) : 1.0);
    }
  }

  /// Tokenizes raw string into lowercase words without punctuation or stopwords.
  static List<String> tokenize(String text) {
    final lower = text.toLowerCase();
    final matches = RegExp(r'[\p{L}\p{N}-]+', unicode: true).allMatches(lower);
    final tokens = <String>[];
    for (final m in matches) {
      final t = m.group(0)!;
      if (t.length >= 2 && !_kStopwords.contains(t)) {
        tokens.add(t);
      }
    }
    return tokens;
  }

  /// Expands query tokens with clinical and vernacular synonyms.
  static List<String> expandQuery(String query) {
    final tokens = tokenize(query);
    final expanded = List<String>.from(tokens);
    for (final t in tokens) {
      final synonyms = _kSynonyms[t];
      if (synonyms != null) {
        expanded.addAll(synonyms);
      }
    }
    return expanded;
  }

  /// Retrieves relevant clinical documents matching the given natural language query.
  List<AshaLocalRetrievalResult> retrieve(
    String query, {
    int topK = 2,
    double minScore = 0.08,
  }) {
    final queryTokens = expandQuery(query);
    if (queryTokens.isEmpty || _documents.isEmpty) return const [];

    final numDocs = _documents.length;
    final queryCounts = <String, int>{};
    for (final t in queryTokens) {
      queryCounts[t] = (queryCounts[t] ?? 0) + 1;
    }
    final queryTotal = queryTokens.length;
    final queryVector = <String, double>{};
    var queryNormSq = 0.0;

    queryCounts.forEach((term, count) {
      final tf = count / queryTotal;
      final idf = math.log((numDocs + 1) / ((_docFreqs[term] ?? 0) + 1)) + 1.0;
      final weight = tf * idf;
      queryVector[term] = weight;
      queryNormSq += weight * weight;
    });

    final queryNorm = queryNormSq > 0 ? math.sqrt(queryNormSq) : 1.0;
    final scored = <AshaLocalRetrievalResult>[];

    for (var i = 0; i < _documents.length; i++) {
      final doc = _documents[i];
      final docVec = _docVectors[i];
      final docNorm = _docNorms[i];

      // Vector cosine similarity
      var dotProduct = 0.0;
      queryVector.forEach((term, weight) {
        dotProduct += weight * (docVec[term] ?? 0.0);
      });
      final cosine = (queryNorm * docNorm) > 0 ? dotProduct / (queryNorm * docNorm) : 0.0;

      // Keyword and title match boost
      final queryLower = query.toLowerCase();
      var kwMatches = 0;
      for (final kw in doc.keywords) {
        if (queryLower.contains(kw)) kwMatches++;
      }
      var titleMatches = 0;
      final docTitleLower = doc.title.toLowerCase();
      for (final tok in queryTokens) {
        if (docTitleLower.contains(tok)) titleMatches++;
      }

      final boost = (kwMatches * 0.15) + (titleMatches * 0.10);
      final finalScore = cosine + boost;

      if (finalScore >= minScore) {
        final snippet = _extractBestSnippet(doc.content, queryTokens);
        scored.add(AshaLocalRetrievalResult(
          documentId: doc.id,
          title: doc.title,
          category: doc.category,
          snippet: snippet,
          score: double.parse(finalScore.toStringAsFixed(4)),
        ));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).toList();
  }

  String _extractBestSnippet(String content, List<String> queryTokens) {
    final sentences = content.split(RegExp(r'(?<=[.!?\n])\s+'));
    var best = '';
    var maxOverlap = -1;

    for (final s in sentences) {
      final trimmed = s.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      var overlap = 0;
      for (final tok in queryTokens) {
        if (lower.contains(tok)) overlap++;
      }
      if (overlap > maxOverlap) {
        maxOverlap = overlap;
        best = trimmed;
      }
    }

    return best.isNotEmpty
        ? (best.length > 300 ? '${best.substring(0, 300)}…' : best)
        : content.substring(0, math.min(300, content.length));
  }
}
