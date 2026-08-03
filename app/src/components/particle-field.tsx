"use client"

import { useEffect, useRef } from "react"

interface Particle {
  x: number
  y: number
  vx: number
  vy: number
  r: number
  hue: number
  phase: number
}

export function ParticleField() {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext("2d")
    if (!ctx) return

    let raf = 0
    let particles: Particle[] = []
    const mouse = { x: -9999, y: -9999 }
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2)
      canvas.width = canvas.offsetWidth * dpr
      canvas.height = canvas.offsetHeight * dpr
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      const count = Math.min(110, Math.floor((canvas.offsetWidth * canvas.offsetHeight) / 16000))
      particles = Array.from({ length: count }, () => spawn())
    }

    const spawn = (): Particle => {
      const w = canvas.offsetWidth
      const h = canvas.offsetHeight
      return {
        x: Math.random() * w,
        y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.35,
        vy: (Math.random() - 0.5) * 0.35,
        r: 1 + Math.random() * 1.8,
        hue: 260 + Math.random() * 60,
        phase: Math.random() * Math.PI * 2,
      }
    }

    const onMouse = (e: MouseEvent) => {
      const rect = canvas.getBoundingClientRect()
      mouse.x = e.clientX - rect.left
      mouse.y = e.clientY - rect.top
    }
    const onLeave = () => {
      mouse.x = -9999
      mouse.y = -9999
    }

    const t0 = performance.now()
    const step = (now: number) => {
      const w = canvas.offsetWidth
      const h = canvas.offsetHeight
      const t = (now - t0) / 1000
      ctx.clearRect(0, 0, w, h)

      // Aurora blobs drifting behind the network.
      const blobs: Array<[number, number, number]> = [
        [0.25 + 0.12 * Math.sin(t * 0.11), 0.2 + 0.1 * Math.cos(t * 0.09), 320],
        [0.78 + 0.1 * Math.cos(t * 0.13), 0.28 + 0.12 * Math.sin(t * 0.11), 290],
        [0.5 + 0.18 * Math.sin(t * 0.07), 0.85 + 0.08 * Math.cos(t * 0.1), 275],
      ]
      for (const [bx, by, hue] of blobs) {
        const g = ctx.createRadialGradient(bx * w, by * h, 0, bx * w, by * h, Math.max(w, h) * 0.4)
        g.addColorStop(0, `hsla(${hue}, 90%, 60%, 0.10)`)
        g.addColorStop(1, "hsla(0, 0%, 0%, 0)")
        ctx.fillStyle = g
        ctx.fillRect(0, 0, w, h)
      }

      // Update and draw particles.
      for (const p of particles) {
        p.x += p.vx
        p.y += p.vy
        p.phase += 0.02

        // Gentle sine sway.
        p.x += Math.sin(t * 0.4 + p.phase) * 0.12
        p.y += Math.cos(t * 0.35 + p.phase) * 0.12

        // Soft attraction to cursor.
        const dx = mouse.x - p.x
        const dy = mouse.y - p.y
        const d2 = dx * dx + dy * dy
        if (d2 < 16000) {
          const d = Math.sqrt(d2) || 1
          p.x += (dx / d) * 0.6
          p.y += (dy / d) * 0.6
        }

        // Wrap around edges.
        if (p.x < -10) p.x = w + 10
        if (p.x > w + 10) p.x = -10
        if (p.y < -10) p.y = h + 10
        if (p.y > h + 10) p.y = -10

        // Twinkle.
        const twinkle = 0.5 + 0.5 * Math.sin(t * 1.6 + p.phase)
        ctx.beginPath()
        ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2)
        ctx.fillStyle = `hsla(${p.hue}, 85%, 70%, ${0.45 + 0.5 * twinkle})`
        ctx.fill()
      }

      // Connecting lines.
      for (let i = 0; i < particles.length; i++) {
        const a = particles[i]
        for (let j = i + 1; j < particles.length; j++) {
          const b = particles[j]
          const dx = a.x - b.x
          const dy = a.y - b.y
          const dist = Math.sqrt(dx * dx + dy * dy)
          if (dist < 120) {
            const alpha = (1 - dist / 120) * 0.22
            ctx.strokeStyle = `hsla(265, 80%, 70%, ${alpha})`
            ctx.lineWidth = 0.6
            ctx.beginPath()
            ctx.moveTo(a.x, a.y)
            ctx.lineTo(b.x, b.y)
            ctx.stroke()
          }
        }
      }

      raf = requestAnimationFrame(step)
    }

    resize()
    window.addEventListener("resize", resize)
    if (!reduced) {
      window.addEventListener("mousemove", onMouse)
      window.addEventListener("mouseleave", onLeave)
      raf = requestAnimationFrame(step)
    } else {
      step(t0)
    }

    return () => {
      cancelAnimationFrame(raf)
      window.removeEventListener("resize", resize)
      window.removeEventListener("mousemove", onMouse)
      window.removeEventListener("mouseleave", onLeave)
    }
  }, [])

  return <canvas ref={canvasRef} className="absolute inset-0 h-full w-full" aria-hidden="true" />
}
