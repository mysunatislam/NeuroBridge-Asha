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
  parkinsonsTremor,
  ventilatorTrach,
  painAssessment,
  cognitiveTbi,
  sleepNightSafety,
  bowelBladderCrisis,
  medicationSafety,
  mentalHealthEmpathy,
  strokeRehabilitation,
  speechTherapy,
  autismSupport,
  icuCommunication,
  physiotherapy,
  caregiverGuidelines,
  userSpecificInstructions,
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
  'জল': ['water', 'hydration', 'thirsty'],
  'পানি': ['water', 'hydration', 'thirsty'],
  'thirsty': ['hydration', 'drinking', 'water', 'thirst'],
  'thirst': ['hydration', 'drinking', 'water'],
  'drink': ['water', 'hydration', 'dysphagia', 'swallow'],
  'swallowing': ['dysphagia', 'choking', 'aspiration', 'water'],
  'swallow': ['dysphagia', 'choking', 'aspiration', 'water'],
  'কাঁপুনি': ['seizure', 'convulsion', 'tremor', 'shaking'],
  'খিঁচুনি': ['seizure', 'convulsion'],
  'seizure': ['convulsion', 'airway', 'recovery', 'first aid', 'epilepsy'],
  'convulsion': ['seizure', 'cushion', 'recovery', 'airway'],
  'choking': ['airway', 'obstruction', 'distress', 'breathing', 'cough', 'suction'],
  'choke': ['airway', 'obstruction', 'distress', 'breathing', 'cough'],
  'breathe': ['airway', 'respiration', 'choking', 'distress', 'ventilator'],
  'breathing': ['airway', 'respiration', 'choking', 'distress', 'ventilator', 'oxygen'],
  'dysreflexia': ['autonomic', 'hypertension', 'blood pressure', 'headache', 'spinal', 'catheter'],
  'headache': ['dysreflexia', 'blood pressure', 'hypertension', 'catheter'],
  'fatigue': ['als', 'mnd', 'micro-gesture', 'dwell', 'pacing', 'weakness'],
  'tired': ['fatigue', 'als', 'energy', 'dwell', 'rest'],
  'weak': ['fatigue', 'als', 'energy', 'dwell', 'rest'],
  'cramp': ['als', 'fatigue', 'fasciculation', 'spasm', 'rest'],
  'tremor': ['dwell', 'sensitivity', 'parkinson', 'resting', 'smoothing', 'shaking'],
  'parkinson': ['tremor', 'rigidity', 'bradykinesia', 'freezing', 'dwell'],
  'shaking': ['tremor', 'parkinson', 'seizure', 'rigidity'],
  'battery': ['charging', 'telemetry', 'wheelchair', 'pi', 'power'],
  'screen': ['caption', 'wheelchair', 'display', 'lcd'],
  'display': ['caption', 'wheelchair', 'screen', 'lcd'],
  'reposition': ['pressure', 'sore', 'injury', 'turning', 'bed', 'tilt'],
  'turning': ['pressure', 'sore', 'reposition', 'skin', 'ulcer'],
  'ulcer': ['pressure', 'sore', 'reposition', 'skin', 'ischemia'],
  'trach': ['tracheostomy', 'ventilator', 'suction', 'mucus', 'airway'],
  'tracheostomy': ['trach', 'ventilator', 'suction', 'mucus', 'airway', 'passy-muir'],
  'suction': ['trach', 'mucus', 'airway', 'phlegm', 'aspiration'],
  'mucus': ['suction', 'trach', 'phlegm', 'airway', 'choking'],
  'pain': ['aching', 'hurts', 'discomfort', 'painad', 'flacc', 'wong-baker'],
  'hurts': ['pain', 'discomfort', 'aching'],
  'ব্যথা': ['pain', 'hurts', 'discomfort'],
  'কষ্ট': ['distress', 'pain', 'difficulty'],
  'catheter': ['bladder', 'dysreflexia', 'urine', 'foley', 'blockage', 'kink'],
  'urine': ['catheter', 'bladder', 'foley', 'dysreflexia'],
  'bladder': ['catheter', 'urine', 'dysreflexia', 'fullness'],
  'bowel': ['dysreflexia', 'impaction', 'constipation'],
  'medicine': ['pill', 'medication', 'dose', 'swallow', 'crushing', 'schedule'],
  'pill': ['medicine', 'medication', 'swallow', 'dysphagia'],
  'ওষুধ': ['medicine', 'pill', 'medication'],
  'panic': ['anxiety', 'fear', 'calm', 'reassurance', 'breathing'],
  'scared': ['panic', 'fear', 'reassurance', 'calm'],
  'afraid': ['panic', 'fear', 'reassurance', 'calm'],
  'depressed': ['sad', 'distress', 'empathy', 'crying'],
  'lonely': ['isolation', 'empathy', 'companion', 'support'],
  'ঘুম': ['sleep', 'night', 'bed', 'elevation'],
  'sleep': ['night', 'elevation', 'aspiration', 'turning', 'position'],
  'rehab': ['stroke', 'exercise', 'motor', 'recovery', 'physiotherapy', 'rehabilitation'],
  'exercise': ['rehab', 'stretching', 'movement', 'physiotherapy', 'mobility'],
  'ব্যায়াম': ['rehab', 'exercise', 'stretching', 'movement', 'physiotherapy'],
  'স্ট্রোক': ['stroke', 'hemiparesis', 'paralysis', 'rehab'],
  'speech': ['articulation', 'phoneme', 'dysarthria', 'pacing', 'therapy'],
  'autism': ['sensory', 'schedule', 'regulation', 'visual', 'overload'],
  'icu': ['intubation', 'ventilator', 'suction', 'tracheostomy', 'blink'],
  'physiotherapy': ['stretch', 'range', 'motion', 'neck', 'spasticity', 'mobility'],
  'rahim': ['profile', 'twin', 'bangla', 'patient'],
  'caregiver': ['transfer', 'ergonomics', 'burnout', 'nurse', 'alert'],
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
        'the wheelchair companion screen for family and caregivers.',
  ),
  AshaKnowledgeDocument(
    id: 'als-bulbar-02',
    title: 'Advanced Bulbar ALS: Secretion Management, Sialorrhea & BiPAP Ventilation Support',
    category: AshaKnowledgeCategory.alsMnd,
    keywords: [
      'als', 'bulbar', 'sialorrhea', 'saliva', 'bipap', 'ventilation', 'secretions',
      'choking', 'suction', 'cough assist', 'breathing'
    ],
    summary: 'Clinical guidelines for managing excessive oral secretions and non-invasive ventilation comfort in bulbar ALS.',
    content: 'Bulbar-onset ALS impairs pharyngeal clearance, leading to pooling secretions and respiratory strain:\n'
        '1. Secretion Management: For thick secretions, ensure adequate baseline hydration and humidification. For thin saliva pooling '
        '(sialorrhea), oral suction should be placed within comfortable reach. Postural drainage with gentle forward tilt helps.\n'
        '2. Non-Invasive Ventilation (BiPAP): When orthopnea or dyspnea occurs, prompt caregiver assistance to fit the BiPAP mask. '
        'Ensure the mask cushion does not compromise visual field needed for camera gaze or hand tracking.\n'
        '3. Cough Assist: Ineffective mechanical cough requires mechanical insufflation-exsufflation. Watch for paradoxical breathing or air hunger.',
  ),
  AshaKnowledgeDocument(
    id: 'stroke-apraxia-02',
    title: 'Apraxia of Speech & Visual Symbol Grids for Post-Stroke Communication',
    category: AshaKnowledgeCategory.strokeAphasia,
    keywords: [
      'apraxia', 'stroke', 'motor speech', 'articulation', 'visual grid', 'symbols',
      'scanning', 'pacing', 'one-touch'
    ],
    summary: 'Access strategies differentiating apraxia of speech from cognitive aphasia using high-contrast icon boards.',
    content: 'Apraxia of speech impairs the motor programming of articulatory gestures despite intact linguistic comprehension:\n'
        '1. Separate Speech Execution from Cognition: The patient knows exactly what they want to convey. Avoid childish speech or simplistic answers.\n'
        '2. High-Contrast AAC Grids: Present visual icons with simultaneous textual captions. Use 1-touch or micro-dwell gesture confirmations.\n'
        '3. Multi-Modal Affirmation: Mirror selected phrases simultaneously in audio via Samantha TTS and visually on the wheelchair companion screen.',
  ),
  AshaKnowledgeDocument(
    id: 'sci-orthostatic-02',
    title: 'Orthostatic Hypotension Management in High-Level Spinal Cord Injury',
    category: AshaKnowledgeCategory.spinalCordInjury,
    keywords: [
      'orthostatic', 'hypotension', 'dizziness', 'lightheaded', 'fainting', 'sci',
      'tilt', 'blood pressure', 'compression stockings', 'abdominal binder'
    ],
    summary: 'Management of blood pressure drops during upright wheelchair tilting and transfers in tetraplegia.',
    content: 'Loss of sympathetic tone in high-level SCI frequently causes venous pooling and acute blood pressure drops upon sitting up:\n'
        '1. Symptom Recognition: Lightheadedness, blurred vision, dizziness, yawning, or pallor when the wheelchair tilts forward or reclines upright.\n'
        '2. Immediate Action: Recline or tilt the wheelchair back immediately (elevate legs above heart level) until symptoms resolve.\n'
        '3. Gradual Elevation: Use power tilt controls to elevate the patient in 10-15 degree increments over 5-10 minutes.\n'
        '4. Supportive Wear: Verify abdominal binders and elastic compression stockings are snugly applied prior to morning transfers.',
  ),
  AshaKnowledgeDocument(
    id: 'parkinsons-tremor-01',
    title: 'Parkinson\'s Disease: Resting Tremor Filtering, Dwell Smoothing & Freezing of Gait',
    category: AshaKnowledgeCategory.parkinsonsTremor,
    keywords: [
      'parkinson', 'tremor', 'shaking', 'rigidity', 'bradykinesia', 'freezing',
      'dwell', 'filter', 'smoothing', 'micro-movement'
    ],
    summary: 'Algorithmic filtering for Parkinsonian 4-6 Hz resting tremors, dwell smoothing, and motor freezing prompts.',
    content: 'Parkinson\'s disease manifests with involuntary 4-6 Hz resting tremors and bradykinesia that can interfere with optical gesture capture:\n'
        '1. Algorithmic Tremor Damping: Configure Asha\'s gesture engine with exponential moving average (EMA) smoothing and raised dwell thresholds (600-800ms) '
        'to reject oscillatory involuntary finger tremors.\n'
        '2. Freezing Episodes: When motor freezing occurs, provide rhythmic metronomic or auditory tones through Samantha voice to re-initiate movement.\n'
        '3. Medication Timing: Performance fluctuates dramatically between "on" and "off" medication states. Note time since last levodopa dose.',
  ),
  AshaKnowledgeDocument(
    id: 'ventilator-trach-01',
    title: 'Tracheostomy & Mechanical Ventilation: Secretion Suctioning & Speaking Valves',
    category: AshaKnowledgeCategory.ventilatorTrach,
    keywords: [
      'tracheostomy', 'trach', 'ventilator', 'suction', 'secretions', 'phlegm',
      'passy-muir', 'cuff', 'cannula', 'airway', 'oxygen'
    ],
    summary: 'Care protocols for ventilator-dependent patients, emergency suctioning indicators, and speaking valve usage.',
    content: 'Ventilator-dependent patients face acute airway obstruction risks from mucus plugging:\n'
        '1. Urgent Suctioning Signs: Increased airway peak pressures, audible bubbling/gurgling in the cannula, drop in SpO2 below 92%, '
        'restlessness, or wide-eyed anxiety require immediate tracheal suctioning.\n'
        '2. Passy-Muir Speaking Valve: Ensure the tracheostomy cuff is completely DEFLATED before applying a speaking valve. '
        'Never occlude a cuffed tube without deflation.\n'
        '3. Emergency Disconnection: If ventilator alarm sounds or tube disconnects, Asha activates high-priority audible caregiver alarm.',
  ),
  AshaKnowledgeDocument(
    id: 'pain-nonverbal-01',
    title: 'Non-Verbal Pain Assessment (PAINAD & FLACC Scales) & Comfort Protocols',
    category: AshaKnowledgeCategory.painAssessment,
    keywords: [
      'pain', 'hurts', 'discomfort', 'non-verbal', 'painad', 'flacc', 'grimacing',
      'guarding', 'wong-baker', 'aching', 'agitation'
    ],
    summary: 'Clinical behavioral pain assessment for non-verbal patients and prompt caregiver triage.',
    content: 'Non-verbal patients cannot speak their pain score. Use validated observational scales:\n'
        '1. Behavioral Indicators: Facial grimacing, furrowed brow, clenching fists, guarded breathing, groaning vocalizations, or restlessness.\n'
        '2. Body Location Pointing: Asha presents an interactive anatomical grid (Head, Chest, Stomach, Back, Arm, Leg) allowing 1-tap confirmation.\n'
        '3. Wong-Baker Visuals: Present 0-10 numerical face scale with visual emotional expressions.\n'
        '4. Nursing Action: Identify acute sources: repositioning needs, full bladder, sheet wrinkles, limb positioning, or musculoskeletal spasm.',
  ),
  AshaKnowledgeDocument(
    id: 'cognitive-pacing-01',
    title: 'Cognitive Fatigue & Traumatic Brain Injury (TBI) AAC Scaffolding',
    category: AshaKnowledgeCategory.cognitiveTbi,
    keywords: [
      'tbi', 'brain injury', 'cognitive', 'fatigue', 'confusion', 'overload',
      'scaffolding', 'processing time', 'simple'
    ],
    summary: 'Reducing cognitive load, visual clutter, and sensory fatigue for post-TBI and anoxic brain injury patients.',
    content: 'Cognitive pacing protocols for neuro-rehabilitation:\n'
        '1. Minimized Visual Complexity: Limit choice screens to 2-4 large high-contrast options. Avoid cluttered 20-icon grids.\n'
        '2. Extended Processing Windows: Wait at least 10 seconds before repeating a prompt or offering assistance.\n'
        '3. Sensory Regulation: Reduce ambient room noise, dim harsh overhead glare, and prioritize short, structured communication bursts.',
  ),
  AshaKnowledgeDocument(
    id: 'sleep-night-safety-01',
    title: 'Nighttime Bedside Monitoring: 30° Head Elevation & Aspiration Aversion',
    category: AshaKnowledgeCategory.sleepNightSafety,
    keywords: [
      'sleep', 'night', 'bed', 'elevation', 'aspiration', 'turning', 'alarm',
      'fall', 'dark', 'nocturnal'
    ],
    summary: 'Nighttime safety guidelines, nocturnal aspiration prevention, and silent monitoring.',
    content: 'Nighttime safety protocol for paralyzed or bed-bound patients:\n'
        '1. Head-of-Bed Elevation: Maintain bed elevated at minimum 30 degrees continuously during sleep to prevent nocturnal reflux and silent aspiration.\n'
        '2. Call-Bell Proximity: Ensure the primary assistive trigger (micro-gesture camera or switch) remains active within natural reach in low-light infrared mode.\n'
        '3. Scheduled Turning: Nighttime repositioning every 2-3 hours remains essential even during sleep; use gentle turning wedges to minimize waking.\n'
        '4. Fall Prevention: Bed rails padded and raised; suction canister powered and primed at bedside.',
  ),
  AshaKnowledgeDocument(
    id: 'bowel-bladder-ad-01',
    title: 'Neurogenic Bladder & Bowel Emergency: Catheter Kinks & Overflow Incontinence',
    category: AshaKnowledgeCategory.bowelBladderCrisis,
    keywords: [
      'catheter', 'foley', 'bladder', 'urine', 'kink', 'fullness', 'autonomic dysreflexia',
      'incontinence', 'retention'
    ],
    summary: 'Troubleshooting urinary drainage and recognizing bladder distension as the primary trigger for life-threatening autonomic crises.',
    content: 'Over 85% of autonomic dysreflexia episodes are triggered by bladder distension or catheter occlusion:\n'
        '1. Catheter Inspection Checklist: Trace tubing from meatus to collection bag. Check for twists, dependent loops, kinks, or sediment obstruction.\n'
        '2. Collection Bag Level: Ensure drainage bag is positioned below the level of the patient bladder to maintain gravity flow.\n'
        '3. Gentle Flushing: If no urine flows and bladder feels palpable, sterile irrigation with 10-15 mL normal saline may clear blockages.\n'
        '4. Urgent Action: If catheter cannot be unblocked and patient is sweating or hypertensive, replace catheter immediately or alert emergency physician.',
  ),
  AshaKnowledgeDocument(
    id: 'medication-dysphagia-01',
    title: 'Safe Medication Administration in Dysphagia & Levodopa Timing Protocols',
    category: AshaKnowledgeCategory.medicationSafety,
    keywords: [
      'medication', 'medicine', 'pill', 'tablet', 'swallowing', 'crushing',
      'dysphagia', 'levodopa', 'timing', 'schedule'
    ],
    summary: 'Safe pill swallowing, avoiding hazardous tablet crushing, and timing critical neurological medications.',
    content: 'Medication administration safety guidelines for neuromuscular patients:\n'
        '1. Crushing Hazards: Never crush enteric-coated (EC) or extended-release (ER/XR) medications. Consult clinical pharmacist for liquid or dissolvable alternatives.\n'
        '2. Applesauce / Puree Vehicle: Administer crushed permitted tablets mixed into thick purees (level 3/4) rather than thin water to prevent choking.\n'
        '3. Levodopa On-Time Adherence: For Parkinson\'s patients, levodopa must be given within 15 minutes of scheduled time. Asha sounds timely medication alarms.\n'
        '4. Anti-Epileptic Consistency: Strict timing of anti-seizure medications prevents breakthrough convulsive status.',
  ),
  AshaKnowledgeDocument(
    id: 'mental-health-paralysis-01',
    title: 'Emotional Validation, Panic De-escalation & Preserving Autonomy in Locked-in Syndrome',
    category: AshaKnowledgeCategory.mentalHealthEmpathy,
    keywords: [
      'panic', 'anxiety', 'fear', 'locked-in', 'isolation', 'autonomy', 'empathy',
      'reassurance', 'dignity', 'depression'
    ],
    summary: 'Compassionate de-escalation for acute panic, helplessness, or sensory isolation in motor-paralyzed individuals.',
    content: 'Being unable to move or speak produces profound situational anxiety and existential helplessness:\n'
        '1. Unconditional Presence: Asha speaks with a calm, steady, unhurried cadence (Samantha standard pace). Validate the patient experience.\n'
        '2. Immediate Control: Offer small, manageable choices immediately: "Would you like me to alert your caregiver, change your display message, or simply stay with you?"\n'
        '3. Breathing Grounding: Guide the patient through slow diaphragmatic breaths: "Breathe in gently through your nose... and slowly breathe out. You are safe."',
  ),
  AshaKnowledgeDocument(
    id: 'bilingual-medical-lexicon-02',
    title: 'Comprehensive Bengali-English Bedside & Medical AAC Lexicon',
    category: AshaKnowledgeCategory.bilingualGuidance,
    keywords: [
      'lexicon', 'bengali', 'bangla', 'dictionary', 'vocabulary', 'words',
      'মেডিকেল', 'ক্লিনিকাল', 'জরুরি', 'শ্বাসকষ্ট', 'পিপাসা'
    ],
    summary: 'Curated 50+ core medical and physiological terms mapped across English and Bengali with semantic equivalence.',
    content: 'Core bedside medical vocabulary mapped for bilingual patient synthesis:\n'
        '1. Biological Needs: Water -> জল/পানি | Hunger -> ক্ষুধা/খাবার | Sleep -> ঘুম/বিশ্রাম | Bathroom -> প্রস্রাব/টয়লেট\n'
        '2. Acute Discomfort: Severe Pain -> তীব্র ব্যথা | Difficulty Breathing -> শ্বাসকষ্ট/দম আটকে আসছে | Cold -> ঠান্ডা লাগছে | Hot -> গরম লাগছে\n'
        '3. Physical Positioning: Sit Up -> সোজা করে বসিয়ে দিন | Lie Down -> শুইয়ে দিন | Turn Left/Right -> পাশ ফিরিয়ে দিন | Fix Pillow -> বালিশ ঠিক করুন\n'
        '4. Personnel & Care: Call Doctor -> ডাক্তার ডাকুন | Call Nurse -> নার্স ডাকুন | Family -> পরিবারের সদস্য | Medication -> সময়মতো ওষুধ দিন',
  ),
  AshaKnowledgeDocument(
    id: 'stroke-rehab-01',
    title: 'Stroke Rehabilitation & Neuroplastic Motor Relearning',
    category: AshaKnowledgeCategory.strokeRehabilitation,
    keywords: [
      'stroke rehabilitation', 'hemiparesis', 'motor relearning', 'neuroplasticity',
      'rehab', 'exercise', 'arm recovery', 'paretic limb', 'constraint', 'repetition'
    ],
    summary: 'Clinical guidelines for stroke motor rehabilitation, neuroplasticity pacing, and bilateral limb guidance.',
    content: 'Stroke Motor Recovery & Rehabilitation Principles:\n'
        '1. Repetitive Task-Oriented Training: Neuroplastic cortical reorganization occurs through focused, purposeful repetitions. '
        'Encourage 10 to 15 deliberate reaching or finger flexion movements per session rather than fatigue-inducing bursts.\n'
        '2. Bilateral Arm Training: Mirroring healthy hand movements with the paretic hand stimulates homologous motor cortex networks.\n'
        '3. Gradual Pacing: Stop immediately if joint pain occurs. Compensatory shoulder hiking should be discouraged in favor of neutral alignment.\n'
        '4. Asha Coaching Loop: Asha initiates gentle prompts: Let us move your neck slowly. Turn right... Good. Now slightly more... Excellent.',
  ),
  AshaKnowledgeDocument(
    id: 'speech-therapy-01',
    title: 'Speech Therapy, Dysarthria Pacing & Articulation Exercises',
    category: AshaKnowledgeCategory.speechTherapy,
    keywords: [
      'speech therapy', 'dysarthria', 'aphasia', 'articulation', 'phoneme',
      'pacing', 'vocal fatigue', 'speech', 'voice', 'swallowing'
    ],
    summary: 'Evidence-based speech therapy strategies, oral-motor drills, and dysarthria compensatory pacing.',
    content: 'Clinical Speech-Language Pathology Guidelines:\n'
        '1. Pacing & Rate Reduction: In flaccid or spastic dysarthria, slowing syllable production improves consonant intelligibility by 40%.\n'
        '2. Phoneme Shaping Drills: Focus on bilabial (/p/, /b/, /m/) and alveolar (/t/, /d/, /n/) sounds with high visual contrast.\n'
        '3. Vocal Fatigue Management: Schedule high-demand conversational exercises after morning rest periods. Provide instant AAC text when vocal cord fatigue sets in.\n'
        '4. Respiratory-Phonatory Coordination: Instruct patient to inhale comfortably through diaphragm before initiating short 2-3 word utterances.',
  ),
  AshaKnowledgeDocument(
    id: 'autism-support-01',
    title: 'Autism Spectrum Support, Sensory Regulation & Low-Cognitive AAC',
    category: AshaKnowledgeCategory.autismSupport,
    keywords: [
      'autism', 'asd', 'sensory overload', 'regulation', 'visual schedule',
      'low cognitive load', 'stimming', 'meltdown', 'aac'
    ],
    summary: 'Sensory regulation protocols, predictable visual AAC scheduling, and de-escalation for neurodivergent users.',
    content: 'Autism Assistive Support Protocol:\n'
        '1. Sensory Predictability: Minimize sudden audio or visual animations. Use consistent muted colors and predictable screen layouts.\n'
        '2. Visual Scheduling: Provide chronological step-by-step cue cards (First water, then rest, then exercise) to reduce transition anxiety.\n'
        '3. Overload De-escalation: If rapid involuntary movements or distress signals are detected, reduce companion audio volume, dim lighting, and present calming breathing prompts.\n'
        '4. Communication Respect: Recognize non-speaking does not mean non-understanding. Keep tone respectful, calm, and direct.',
  ),
  AshaKnowledgeDocument(
    id: 'icu-comm-01',
    title: 'ICU Communication Boards & Acute Intubation AAC Protocols',
    category: AshaKnowledgeCategory.icuCommunication,
    keywords: [
      'icu', 'intensive care', 'intubation', 'endotracheal', 'ventilator',
      'pain scale', 'eye blink', 'critical care', 'non-verbal'
    ],
    summary: 'Fast-path communication boards, binary eye-blink confirmation, and acute pain scales for intubated patients.',
    content: 'Intensive Care Unit (ICU) Communication Standard:\n'
        '1. Binary Eye-Blink Protocol: Two blinks = YES, prolonged eye closure (1.5s) = NO. Allows intubated patients to verify biological needs without vocal cords.\n'
        '2. Priority Biological Grid: Immediate 1-tap access to Pain, Suction airway, Reposition bed, Cold/Hot, Family member.\n'
        '3. PAINAD / CPOT Non-Verbal Scoring: Asha observes facial muscle furrowing and brow tension to estimate pain score (0 to 10) even when patient cannot speak.\n'
        '4. Nurse Call Integration: Urgent ICU requests trigger immediate dual alerts on both bedside display and nurse station webhook.',
  ),
  AshaKnowledgeDocument(
    id: 'physiotherapy-01',
    title: 'Neurological Physiotherapy, Range of Motion & Spasticity Management',
    category: AshaKnowledgeCategory.physiotherapy,
    keywords: [
      'physiotherapy', 'physical therapy', 'range of motion', 'spasticity',
      'contracture', 'neck movement', 'hand stretch', 'joint mobility'
    ],
    summary: 'Bedside and wheelchair range of motion exercises, contracture prevention, and gentle stretching protocols.',
    content: 'Assistive Physiotherapy & Movement Guidelines:\n'
        '1. Cervical & Neck Range of Motion: Gentle lateral rotation (ear toward shoulder) held for 5 seconds improves carotid circulation and reduces cervical tension.\n'
        '2. Passive Wrist & Hand Stretching: Slowly extend fingers using opposite hand or armrest wedge to counteract flexor spasticity common in hemiplegia.\n'
        '3. Postural Alignment: Verify wheelchair pelvis position is seated deep against backrest. Avoid sacral sitting which exacerbates spinal deformities.\n'
        '4. Asha Feedback Loop: Track execution smoothness. Provide positive reinforcement: Good, you completed 5 gentle repetitions today.',
  ),
  AshaKnowledgeDocument(
    id: 'caregiver-guidelines-01',
    title: 'Clinical Caregiver Guidelines, Safe Transfers & Burnout Mitigation',
    category: AshaKnowledgeCategory.caregiverGuidelines,
    keywords: [
      'caregiver guidelines', 'transfer safety', 'body mechanics', 'pressure relief',
      'burnout', 'respite', 'ergonomics', 'care plan'
    ],
    summary: 'Ergonomic patient transfer guidelines, pressure relief schedules, and caregiver wellbeing protocols.',
    content: 'Clinical Guidelines for Caregivers:\n'
        '1. Transfer Safety: Maintain wide base of support, keep knees bent, and bring patient close to body center of gravity before standing transfer.\n'
        '2. Offloading Routine: Set automated reminder every 2 hours for bedbound patients and every 30 minutes for wheelchair sitting to offload sacrum and ischial tuberosities.\n'
        '3. Notification Triage: Use Ashas green/yellow/red priority triage to address critical needs without experiencing constant alarm anxiety.\n'
        '4. Caregiver Self-Care: Ensure regular respite breaks and sleep rotation to prevent chronic physical strain and empathetic exhaustion.',
  ),
  AshaKnowledgeDocument(
    id: 'user-specific-instructions-01',
    title: 'Patient Digital Twin Personalized Care Directives (Rahim Profile)',
    category: AshaKnowledgeCategory.userSpecificInstructions,
    keywords: [
      'user specific', 'digital twin', 'rahim', 'profile', 'preference',
      'bangla', 'hydration schedule', 'call daughter', 'emergency contacts'
    ],
    summary: 'User Digital Twin profile parameters, personal communication preferences, and individualized routines.',
    content: 'Personalized Digital Twin Care Directives:\n'
        '1. Patient Profile: Rahim, 64 years old, recovering from ischemic stroke with right-sided partial motor recovery.\n'
        '2. Preferred Communication: Right hand micro-gestures and eye-blink scanning. Primary language: Bangla, secondary: English.\n'
        '3. Core Routine Requests: Morning water (room temperature), pain relief check at 2 PM, evening video call with daughter (Fatima).\n'
        '4. Active Safety Flags: Fall detection enabled on wheelchair accelerometer. Dysphagia aspiration precautions active (thickened liquids only).\n'
        '5. Prescribed Exercises: Daily 10-minute neck lateral stretches and right-hand finger extension drills guided by Asha.',
  ),
];

/// Fast client-side hybrid TF-IDF & keyword retriever.
class AshaLocalKnowledgeRetriever {
  AshaLocalKnowledgeRetriever({
    List<AshaKnowledgeDocument>? documents,
  }) : _documents = documents ?? kClinicalKnowledgeDocuments {
    _buildIndex();
  }

  static final AshaLocalKnowledgeRetriever instance =
      AshaLocalKnowledgeRetriever();

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
    final matches = RegExp(r'[\p{L}\p{M}\p{N}-]+', unicode: true).allMatches(lower);
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

/// Grounded clinical RAG context for downstream LLM prompting and deterministic synthesis.
class GroundedRagContext {
  const GroundedRagContext({
    required this.query,
    required this.matches,
    required this.formattedContext,
  });

  final String query;
  final List<AshaLocalRetrievalResult> matches;
  final String formattedContext;

  bool get hasMatches => matches.isNotEmpty;
  AshaKnowledgeCategory? get topCategory =>
      matches.isNotEmpty ? matches.first.category : null;
  String? get topTitle => matches.isNotEmpty ? matches.first.title : null;
  String? get topSnippet => matches.isNotEmpty ? matches.first.snippet : null;
}

/// Clinical RAG pipeline that coordinates local retrieval and context augmentation.
class AshaRagPipeline {
  AshaRagPipeline({AshaLocalKnowledgeRetriever? retriever})
      : _retriever = retriever ?? AshaLocalKnowledgeRetriever.instance;

  final AshaLocalKnowledgeRetriever _retriever;

  GroundedRagContext buildGroundedContext(
    String query, {
    int topK = 3,
    double minScore = 0.06,
  }) {
    final matches = _retriever.retrieve(query, topK: topK, minScore: minScore);
    if (matches.isEmpty) {
      return GroundedRagContext(
        query: query,
        matches: const [],
        formattedContext: '',
      );
    }

    final buffer = StringBuffer();
    buffer.writeln('CLINICAL KNOWLEDGE BASE (GROUND TRUTH):');
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      buffer.writeln('${i + 1}. [${m.title}] (${m.category.name}): ${m.snippet}');
    }
    buffer.writeln();
    buffer.writeln('INSTRUCTIONS FOR ASHA:');
    buffer.writeln('- Ground your response in this factual clinical guidance.');
    buffer.writeln('- Speak concisely, empathetically, and clearly (1-2 sentences for Samantha TTS).');
    buffer.writeln('- If patient describes acute distress or danger, recommend safety actions and notify caregiver.');

    return GroundedRagContext(
      query: query,
      matches: matches,
      formattedContext: buffer.toString().trim(),
    );
  }

  String augmentSystemInstruction(String baseInstruction, GroundedRagContext rag) {
    if (!rag.hasMatches) return baseInstruction;
    return '$baseInstruction\n\n${rag.formattedContext}';
  }
}

