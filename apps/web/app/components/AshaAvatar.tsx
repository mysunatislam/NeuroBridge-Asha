import Image from "next/image";

type AshaAvatarProps = {
  variant?: "compact" | "hero";
  decorative?: boolean;
  eager?: boolean;
};

export function AshaAvatar({ variant = "compact", decorative = false, eager = false }: AshaAvatarProps) {
  return (
    <span className={`asha-avatar asha-avatar-${variant}`}>
      <Image
        src="/asha-avatar-new.png"
        width={512}
        height={512}
        alt={decorative ? "" : "Asha, the FingerSpeak companion"}
        aria-hidden={decorative || undefined}
        priority={eager}
        unoptimized
        draggable={false}
      />
      <span className="asha-avatar-spark" aria-hidden="true">✦</span>
    </span>
  );
}
