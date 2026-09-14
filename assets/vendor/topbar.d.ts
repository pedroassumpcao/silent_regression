declare const topbar: {
  config(options: { barColors: Record<number, string>; shadowColor: string }): void
  show(delay?: number): void
  hide(): void
}

export default topbar
