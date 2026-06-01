import * as tf from "@tensorflow/tfjs-core"
import "@tensorflow/tfjs-backend-webgl"
import "@tensorflow/tfjs-backend-cpu"

export async function ensureTfBackend() {
  const attempts = ["webgl", "cpu"]
  const errors = []

  for (const backend of attempts) {
    try {
      await tf.setBackend(backend)
      await tf.ready()
      return tf.getBackend()
    } catch (error) {
      errors.push(`${backend}: ${error?.message || error}`)
    }
  }

  throw new Error(`Could not initialize TensorFlow.js backend (${errors.join("; ")})`)
}
