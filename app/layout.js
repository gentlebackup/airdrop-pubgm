
import './globals.css';

export const metadata = {
  metadataBase: new URL('https://airdrop-pubgm.vercel.app'),

  title: {
    default: 'AIRDROP PUBGM | PUBG Mobile Community',
    template: '%s | AIRDROP PUBGM'
  },

  description:
    'AIRDROP PUBGM is a community platform for PUBG Mobile players to discover activities, challenges, tournaments, and competitive events.',

  applicationName: 'AIRDROP PUBGM',

  generator: 'Next.js',

  manifest: '/manifest.webmanifest',

  appleWebApp: {
    capable: true,
    statusBarStyle: 'black-translucent',
    title: 'AIRDROP PUBGM'
  },

  icons: {
    icon: [
      { url: '/airdrop-pubgm-logo.svg', type: 'image/svg+xml' }
    ],
    apple: [
      { url: '/icon-192.png', type: 'image/png' }
    ]
  },

  keywords: [
    'AIRDROP PUBGM',
    'PUBG Mobile',
    'PUBG Mobile',
    'PUBG Mobile',
    'PUBG Mobile community',
    'PUBG Mobile tournaments',
    'PUBG Mobile challenges',
    'PUBG Mobile 1v1'
  ],


  alternates: {
    canonical: '/'
  },

  openGraph: {
    title: 'AIRDROP PUBGM | PUBG Mobile Community',
    description:
      'A community platform for PUBG Mobile players to discover activities, challenges, tournaments, and competitive events.',
    url: 'https://airdrop-pubgm.vercel.app',
    siteName: 'AIRDROP PUBGM',
    type: 'website'
  },

  twitter: {
    card: 'summary',
    title: 'AIRDROP PUBGM | PUBG Mobile Community',
    description:
      'A community platform for PUBG Mobile players to discover activities, challenges, tournaments, and competitive events.'
  }
};

export const viewport = {
  width: 'device-width',
  initialScale: 1,
  minimumScale: 1,
  maximumScale: 1,
  userScalable: false,
  viewportFit: 'cover',
  themeColor: '#ff9f32'
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
