export type LandingLocale = 'en' | 'ko';

const englishCopy = {
  header: {
    download: 'Download Toki',
    downloadLabel: 'Download the latest Toki release',
    homeLabel: 'Toki home',
    languageLabel: 'Language',
    nav: {
      agents: 'Agents',
      docs: 'Docs',
      privacy: 'Privacy',
      time: 'Work time',
    },
    primaryLabel: 'Primary',
  },
  hero: {
    description:
      'Track tokens, cost, project attribution, and the time agents actually spend working.',
    download: {
      prefix: 'Download Toki ',
      suffix: '',
    },
    facts: 'MACOS · LOCAL DATA · GITHUB RELEASES',
    intro: 'Toki makes the moving parts of AI-assisted work legible.',
    metrics: {
      parallel: {
        label: 'PARALLEL',
        value: '1.21×',
      },
      workTime: {
        label: 'AI WORK TIME',
        value: '4h 13m',
      },
    },
    pill: 'Local-first menu bar app',
    timeLink: 'See how time works',
    title: {
      accent: 'beneath',
      lead: 'The work',
      tail: ' the output.',
    },
    visualizationLabel: 'Visualization of parallel agent activity',
  },
  screenshots: {
    aside: {
      first: 'SIX FOCUSED VIEWS',
      second: 'ONE MENU-BAR HOME',
    },
    pill: 'Live in the popover',
    shots: {
      models: {
        alt: 'Toki Models view',
        caption: 'MODELS — USAGE AND COST',
      },
      projects: {
        alt: 'Toki Projects view',
        caption: 'PROJECTS — ATTRIBUTION IN CONTEXT',
      },
      time: {
        alt: 'Toki Time view',
        caption: 'TIME — DIRECT, DELEGATED, OVERLAP',
      },
    },
    title: 'The context stays close.',
  },
  workTime: {
    description:
      'Toki distinguishes direct work, delegated work, and overlapping streams—then counts overlap once so AI Work Time means something useful.',
    metrics: {
      main: {
        detail: 'The work on the primary stream.',
        label: 'Main-agent work',
        value: 'Direct',
      },
      parallel: {
        detail: 'Total work divided by AI Work Time.',
        label: 'Parallel multiplier',
        value: '1.21×',
      },
      subagent: {
        detail: 'Work occurring on separate streams.',
        label: 'Subagent work',
        value: 'Delegated',
      },
      workTime: {
        detail: 'Wall-clock time with overlap counted once.',
        label: 'AI Work Time',
        value: '4h 13m',
      },
    },
    metricsLabel: 'Toki time measurements',
    pill: 'Time view',
    title: 'A total that knows what happened in parallel.',
  },
  agents: {
    description:
      'Toki reads the supported local usage stores. It does not ask you to reconstruct a workday from browser tabs and invoices.',
    listLabel: 'Supported agent tools',
    pill: 'Supported agents',
    title: 'The tools already in your terminal.',
  },
  privacy: {
    description:
      'Local collection stays on-device. If you opt into Remote Sync, supported usage data is sent as an encrypted snapshot to your configured Hub; no hosted account is required for local use.',
    pill: 'Private by default',
    title: 'Your usage stays yours.',
  },
  download: {
    description:
      'Download the free macOS release from GitHub and let Toki keep the activity behind your agents close at hand.',
    download: {
      prefix: 'Download Toki ',
      suffix: '',
    },
    pill: 'Ready when the work starts',
    quarantine: 'If macOS flags the unsigned app, clear quarantine once',
    source: 'View source',
    title: 'Put the whole run in view.',
  },
  footer: {
    copyright: '© TOKI · LOCAL-FIRST OBSERVABILITY',
    download: 'DOWNLOAD',
    docs: 'DOCS',
    label: 'Footer',
  },
} as const;

type CopyShape<T> = T extends string
  ? string
  : T extends readonly (infer Item)[]
    ? readonly CopyShape<Item>[]
    : T extends object
      ? { readonly [Key in keyof T]: CopyShape<T[Key]> }
      : T;

export type LandingCopy = CopyShape<typeof englishCopy>;

const koreanCopy = {
  header: {
    download: 'Toki 다운로드',
    downloadLabel: '최신 Toki 릴리스 다운로드',
    homeLabel: 'Toki 홈',
    languageLabel: '언어 선택',
    nav: {
      agents: '에이전트',
      docs: '문서',
      privacy: '프라이버시',
      time: '작업 시간',
    },
    primaryLabel: '주요 메뉴',
  },
  hero: {
    description:
      '토큰, 비용, 프로젝트별 사용량과 에이전트가 실제로 일한 시간을 추적하세요.',
    download: {
      prefix: 'Toki ',
      suffix: ' 다운로드',
    },
    facts: 'MACOS · 로컬 데이터 · GITHUB 릴리스',
    intro: 'Toki는 AI와 함께한 작업의 흐름을 한눈에 보여줍니다.',
    metrics: {
      parallel: {
        label: '병렬 실행',
        value: '1.21×',
      },
      workTime: {
        label: 'AI 작업 시간',
        value: '4시간 13분',
      },
    },
    pill: '로컬 우선 메뉴 막대 앱',
    timeLink: '작업 시간 알아보기',
    title: {
      accent: '진짜 작업',
      lead: '결과 뒤에 숨은',
      tail: '을 보다.',
    },
    visualizationLabel: '여러 에이전트가 동시에 작업하는 모습',
  },
  screenshots: {
    aside: {
      first: '핵심 화면 여섯 개',
      second: '메뉴 막대 한곳에서',
    },
    pill: '팝오버에서 바로 확인',
    shots: {
      models: {
        alt: 'Toki 모델 화면',
        caption: '모델 — 사용량과 비용',
      },
      projects: {
        alt: 'Toki 프로젝트 화면',
        caption: '프로젝트 — 맥락 속 기여도',
      },
      time: {
        alt: 'Toki 시간 화면',
        caption: '시간 — 직접 · 위임 · 중첩',
      },
    },
    title: '필요한 맥락은 늘 가까이에.',
  },
  workTime: {
    description:
      'Toki는 직접 작업, 위임 작업, 겹친 흐름을 구분한 뒤 중첩 시간은 한 번만 계산해 AI 작업 시간을 의미 있게 만듭니다.',
    metrics: {
      main: {
        detail: '주 흐름에서 진행된 작업입니다.',
        label: '메인 에이전트 작업',
        value: '직접',
      },
      parallel: {
        detail: '총 작업 시간을 AI 작업 시간으로 나눈 값입니다.',
        label: '병렬 배수',
        value: '1.21×',
      },
      subagent: {
        detail: '별도 흐름에서 진행된 작업입니다.',
        label: '서브에이전트 작업',
        value: '위임',
      },
      workTime: {
        detail: '중첩은 한 번만 센 실제 경과 시간입니다.',
        label: 'AI 작업 시간',
        value: '4시간 13분',
      },
    },
    metricsLabel: 'Toki 작업 시간 측정값',
    pill: '시간 화면',
    title: '겹친 시간은 한 번만 계산합니다.',
  },
  agents: {
    description:
      'Toki는 지원되는 로컬 사용 기록을 읽습니다. 브라우저 탭과 청구서를 오가며 하루를 되짚을 필요가 없습니다.',
    listLabel: '지원하는 에이전트 도구',
    pill: '지원 에이전트',
    title: '이미 터미널에서 쓰는 도구 그대로.',
  },
  privacy: {
    description:
      '로컬 모드에서는 사용 기록이 기기 안에 머뭅니다. 원격 동기화를 켜면 지원되는 사용 데이터가 암호화된 스냅샷으로 설정한 Hub에 전송되며, 로컬 사용에는 호스팅 계정이 필요하지 않습니다.',
    pill: '처음부터 비공개',
    title: '사용 기록은 당신에게만.',
  },
  download: {
    description:
      'GitHub에서 무료 macOS 릴리스를 내려받고, 에이전트 뒤에서 일어나는 모든 활동을 가까이 두세요.',
    download: {
      prefix: 'Toki ',
      suffix: ' 다운로드',
    },
    pill: '작업이 시작되면 바로',
    quarantine: 'macOS가 서명되지 않은 앱을 차단하면 격리를 한 번 해제하세요',
    source: '소스 보기',
    title: '모든 실행을 한눈에.',
  },
  footer: {
    copyright: '© TOKI · 로컬 우선 사용량 관측',
    download: '다운로드',
    docs: '문서',
    label: '하단 메뉴',
  },
} as const satisfies LandingCopy;

const copyByLocale: Readonly<Record<LandingLocale, LandingCopy>> = {
  en: englishCopy,
  ko: koreanCopy,
};

export function getLandingCopy(locale: LandingLocale): LandingCopy {
  return copyByLocale[locale];
}
